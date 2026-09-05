# Custom vault UI

We build it ourselves from
[`flap-vault-component-template`](https://github.com/flap-sh/flap-vault-component-template) and hand
over a zip. This page is what we intend to build, what the component already does today, and the one
thing we cannot do without a ruling from you. It is not a request for you to design anything.

Nothing is packaged yet, and `vault-ui/` in our repository deliberately produces no zip. Flap accepts
only what `yarn vault:package` writes — the format-version 6 `flap-vault-package.json` marker, the
`@flapsdk/vault-runtime` gitHead provenance, recursive source/schema/E2E hashes and
`qa/e2e-report.json` — and Workbench rejects a hand-assembled archive. So the four files sit in the
repository as source, and packaging waits for the step described at the bottom of this page.

## What Flap's own checker says

We ran `node scripts/vault-check.mjs keel` from a checkout of `flap-vault-ui-template`, with the
four files exactly as they are in `vault-ui/`. The full JSON is committed at
[`vault-check.json`](vault-check.json).

It started at **10 blocking issues** and is now at **one**. What it caught that nothing of ours
did:

| What the checker found | Status |
|---|---|
| `contract-boundary/missing-contract-label` ×3, `undeclared-contract-address` ×3 | fixed — every call now passes `contract: "vault"` and `address: context.vaultAddress`. A local alias holding the same value reads to the static check as an undeclared external address |
| a type error: `useFlapSdk(injected)` takes no arguments | fixed — the component had never been compiled against the real SDK |
| `manual-review/action-stage-gating` | fixed — reads `host.marketPhase`, gates through `isActionAvailableForPhase`. Stage is `"both"`: the three work functions move BNB the vault already holds and are not bonding-curve trades |
| `risk-status/missing-host-risk-state` | fixed — reads the host risk level, renders it in the first card, and shows a danger notice when it is unavailable |
| `manifest-schema/invalid-artifact-id` | fixed — `artifactId` is generated locally as `vaultui_keel_<ULID>`, which is ours to mint rather than Workbench's to assign |
| `manifest-binding/disallowed-binding-field` | fixed — a `note` key we had added is not among the five allowed binding keys |
| `preview-registration/missing-vault-module` | not ours — `src/vaults/index.ts` belongs to the template and `vault:scaffold` writes it |
| **`manifest-binding/missing-test-token`** | **open, and this is the question below** |

Our own `tools/check-vault-ui.mjs` reported eight passes throughout all of that. It compares the
ABI slice against the forge output and keeps the locales in step; it does not compile the
component and knows nothing about Flap's rules. We have written that limitation into the file
rather than leave it looking authoritative.

## The one remaining blocker, and the question

`match.bindings` needs at least one real deployed ERC20 whose address ends in `7777` or `8888`.
`vault:e2e` passes it to the preview as `?tokenAddress=`, and `vault:package` needs the report
`vault:e2e` writes.

Keel has no such token. No token has been launched, and one cannot be launched on BSC testnet:
building the position must flash-borrow, and testnet has no PancakeSwap V3 liquidity to borrow
from — `getPool` returns the zero address for 32 WBNB pairs across four fee tiers.

We could satisfy the rule today by pointing the binding at some unrelated 7777 token. The checker
would pass: it verifies the suffix and that the address is a real ERC20, not that the token is
ours. We have not done that. The component would render dashes against a vault that does not
exist, and a green package built on that proves nothing.

**So the question is which you prefer:** a mainnet launch first, so the binding names Keel's own
token; a testnet environment or pool you designate, so a token can exist on 97; or a package
submitted with this binding empty and the gap stated. We will do whichever you say.

## Binding

Factory-scoped to `0xf68e42BB99baBD2D0e2c365B438c81E4269AaC7f`, on chain 56 and on chain 97. The
address is identical on both chains because it is the same bytecode from the same deployer
`0x1544A8fCE3a3c39E0a744a13392981bEcDF014f4` at the same nonce. Both bindings are already written
into `manifest.json`, and locales are `en` and `zh`, both complete. The file is not
`vault:check`-clean yet, and we would rather name the gaps than have you find them. `artifactId` is
still a placeholder, and filling it is ours to do, not Workbench's: `vault:scaffold` generates it
locally as `vaultui_<folder-name>_<26-char ULID>`, and `--artifact-id` exists only to restore a known
identity. Workbench owns runtime versions and storage paths, not this field. No binding carries a
`tokenAddresses` entry, which is blocking on its own (`manifest-binding/missing-test-token`) and is
the same blocker as the one at the bottom of this page. And the chain-97 entry carries a `note` key
explaining why no vault can exist there; a binding entry may hold only `chainId`, `factoryAddress`,
`vaultAddresses`, `tokenAddresses` and `externalContracts`, so that note is blocking too
(`manifest-binding/disallowed-binding-field`) and belongs on this page instead. All three close in
the one scaffold run that the token blocks.

One warning that matters specifically because the binding is by factory address: a superseded factory
`0xE7EC91f5a78c413cDF2F1140B29d51cAfFAfE535` also exists on chain. It is retired — its
`vaultDataSchema` still described the project share as 40% — and it must never be bound. Only the
address above is current.

## The panels, and the call behind each

| Panel | Reads | Notes |
|---|---|---|
| Next settlement | `pendingRequestId`, `nextSettlementIn`, `pendingAction` | The page's lead, not the buttons. Scheduled or idle comes from the request id; the countdown from `nextSettlementIn`; `pendingAction` names what the wake will do — reduce leverage, build the position, distribute the gain, rebalance, or check again |
| Waiting to be deployed | `pendingRevenue` | Tax that has arrived but is not in the position yet |
| Position | `nav`, `currentLeverage`, `TARGET_LEVERAGE` | Treasury in BNB, current leverage against the 3e18 target |
| Health | `healthBps`, `MIN_HEALTH_BPS` | The liquidating move is derived on the page as 1 − 1/health; an unlevered vault returns `type(uint256).max` and renders as "no debt", never as a huge number |
| Health scale | `healthBps`, `MIN_HEALTH_BPS` | Static inline SVG. Left edge is the Venus liquidation point, a notch marks the vault's own floor (`MIN_HEALTH_BPS` 12000), the mark is where the position stands |
| Paid out | `totalHarvested`, `totalToProject` | Holders and project, all time |
| Manual fallback | `deployPending`, `harvest`, `rebalance`, `kickstart` | The only write forms. `kickstart` is hidden while a settlement is already scheduled; each of the other three pays the caller a bounty (`DEPLOY_BOUNTY_BPS` 25, `HARVEST_BOUNTY_BPS` 50, `REBALANCE_BOUNTY_BPS` 30) |

Every read goes through `context.vaultAddress` with the generated ABI. No address is hardcoded in the
component. The countdown is ticked locally once a second rather than re-read from chain, and the
whole set of reads refetches on `sdk.refetchNonce`.

The 70/30 line under the payout panel is static copy, not a read: `PROJECT_SHARE_BPS` is 3000, a
compile-time constant with no setter, no role and no governance path, so there is nothing for the
page to poll. One thing can still move it, and the boundary is worth stating exactly:
`LeverBeacon` is an `UpgradeableBeacon` whose ownership goes to the Flap Guardian inside the
constructor, so the Guardian — never us, never the deployer — can replace the implementation behind
every vault, and every constant in it. That is the rule 009 proxy exemption working as intended, and
it is the only path by which this number changes. `PROJECT_SHARE_BPS` ships in the ABI for that
reason among others: if you would rather the page read it than assert it, the read survives an
upgrade and the static copy does not.

`VaultABI.ts` is generated by `tools/gen-vault-abi.mjs` from the forge artefact and pruned to a
22-name allowlist; the script aborts if any name on that list is not on `LeverVault`. Fifteen of the
twenty-two are rendered today — eleven reads and four writes. The other seven (`costBasis`,
`needsRebalance`, `positionUsd`, `totalDeployed`, `totalReceived`, `unrealisedGain`,
`PROJECT_SHARE_BPS`) ship so a second panel does not require a contract change. We do not hand-write
the slice: it drifts silently the moment a signature changes, and a gate that only counts arguments
cannot see a type drift.

## The boundaries the component already obeys

**No outbound request of any kind.** No routers, no bridges, no price endpoint, no analytics, no
external link. Everything the page shows it read from the vault itself.

**No font travels with the package.** The default Vault UI package is the strict four files —
`Component.tsx`, `manifest.json`, `VaultABI.ts`, `i18n.json` — and remote loading is out, so the
component names `ui-monospace, 'SF Mono', Menlo, Consolas, monospace` and takes whatever the system
gives it. keelperp.fun ships Geist and Geist Mono as self-hosted faces; that part of our look does not
survive into the package, and we are fine with that. One supported route does exist and we are
declining it rather than missing it: a mode-less `7777` Vault UI that declares the `three-r3f-v1`
capability may ship statically reachable font files, under a per-font byte cap
(`capability-assets/font-too-large`) and a `manual-review/mini-app-3d-font` licence review.
Declaring a 3D capability profile to carry a typeface into a page of numbers is not a review we would
ask you for. If you would rather we take it, say so.

**An unloaded value renders as an em dash, never as 0.** Every reader returns `undefined` until it
has an answer, and every formatter maps `undefined` to `—`. This is a page someone decides how much
money to put in on: a treasury that has not loaded must not read as an empty treasury, and a health
number that failed to load must not read as a liquidation.

**The health scale is static SVG geometry.** `rect` and `circle` positioned from React state — no
text node, no external reference, no fetched asset, no DOM query. It is `role="presentation"` and
`aria-hidden`, and the health figure it illustrates is printed as text beside it, so nothing is
carried by the drawing alone.

Those four are intended and reviewed by hand, and nothing we run gates them — we would rather say
so than let a green count imply otherwise. `tools/check-vault-ui.mjs` runs inside `scripts/test.sh`
and asserts that the four files are present, that regenerating `VaultABI.ts` is a no-op against the
current forge output, that every name the component calls exists in the ABI, that `en` and `zh` cover
the same keys, and that every `t()` key is defined — 8 of the 69 checks we report green (28 forge
tests + 33 live-state assertions + 8 vault-UI checks). That is drift protection: it catches a button
that would revert and a locale that would render blank. It asserts nothing about outbound requests,
fonts, em dashes or SVG geometry. The template's own `vault:check` is where the first two of the four
are machine-checked (`endpoint-policy/direct-fetch`, `forbidden-api/browser-network`,
`package-structure/disallowed-vault-file`), and we have not run it yet: it wants a scaffolded folder
and a bound token, which is the blocker below. The em dash rule and the static-scale rule are ours
to hold, and we hold them by reading the one file they live in.

## The blocker, and the question

`yarn vault:scaffold` and `yarn vault:check` need a real deployed ERC20 whose address ends in `7777`
or `8888`, bound under `match.bindings[].tokenAddresses` — `vault:check` reads its bytecode and ERC20
metadata on the declared chain. `vault:e2e` then drives the preview against that token, and
`yarn vault:package` refuses without the passing, non-stale `qa/e2e-report.json` that run writes. The
chain starts at a token that exists.

**No KEEL token has been launched, on any chain.** The launch parameters are decided and written down
— name Keel, symbol KEEL, 2% buy and 2% sell tax, `mktBps` 8000 to the vault and `dividendBps` 2000
straight to dividends, `TOKEN_TAXED_V3`, native BNB quote — and `script/LaunchKeel.s.sol` is written
against `newTokenV6WithVault`, but that call has never been made anywhere.

**And it cannot be made on testnet.** The factory is deployed on 97 at the same address, but no vault
can be created there, and the reason is measured rather than assumed. The build path must
flash-borrow — Venus checks collateral before borrowed funds become collateral — and BSC testnet's
PancakeSwap V3 is empty: `getPool` returned the zero address for 32 WBNB pairs across 4 fee tiers,
and no `PoolCreated` event appears in the last 40,000 blocks. Both test USDT contracts gate `mint()`
behind `Ownable` with a third party as owner, so we cannot build a pool ourselves either. Venus is
live on 97 (vBNB listed, 16.3 tBNB borrowable); the missing dependency is the swap venue, not the
lender. Since `newTokenV6WithVault` mints the token and creates the vault in one call, an E2E run
there would at best certify a vault that could never build a position — and it would not fail
loudly either. Every read succeeds on an unlevered vault: `currentLeverage` returns 0 and renders
"0.00×", `healthBps` returns `type(uint256).max` while debt is zero and renders as "no debt", and
`nav` returns the idle BNB balance and renders as a number. The one em dash would be the derived
liquidating move, which has no meaning without debt. The page would render clean and the report
would pass, having exercised neither the build nor the harvest nor the rebalance — the three paths
worth certifying.

So we would like you to pick one:

1. **Mainnet first.** We launch KEEL on chain 56 once SB-01 (the 30% project share) is ruled on and
   an account holding `VAULT_ADMIN_ROLE` has called `registerVaultFactory`, then bind the E2E to the
   live token and submit the package after that. This is the option we would choose on our own, and
   it is also the one that puts a live token ahead of your sign-off — which is your call, not ours.
2. **A testnet environment you designate.** If you have a chain, or a seeded WBNB PancakeSwap V3 pool
   on 97, we will run `vault:check` → `vault:e2e` → `vault:package` there and hand over the zip
   without touching mainnet. One thing to know before you choose it: Venus's collateral factor on 97
   is 70% against mainnet's 80%, and `_cf()` reads it from chain, so the health floor would bind
   leverage near 2.4x. The E2E would pass, but against a different position than chain 56 runs.
3. **A package with no E2E binding.** If Workbench will accept it, we submit the four files with no
   `qa/e2e-report.json` and complete the E2E after launch. What this option cannot include is a
   `vault:check`-clean scaffold: with no real `7777`/`8888` token to bind, the missing
   `tokenAddresses` entry is blocking by itself, so it hands you a package that no gate has passed.

## One smaller confirmation

The component paints its own light surface — a paper ground with near-black ink, a copper accent on
the countdown, sea green for health and holder payouts, rust for the liquidation edge and the risk
line — inside what every shipped example renders as a dark shell. We will not call the template
silent on this: `docs/ui-pattern-snippets.md` asks for "the current Flap Vault visual system: dark
neutral business surfaces, white low-opacity borders, compact status pills, dense metric strips, and
one clear primary action panel". No `vault:check` rule blocks a light ground — the visual rule we can
find, `visual-policy/row-heavy-dashboard`, is about shape, not colour — so this is a departure from
written house style rather than from a gate. keelperp.fun itself is dark, so it is not our own brand
we are defending either. If a light panel is a problem, say so and it goes dark.

## Timing

We assume the custom UI is looked at after the vault itself. This page is here so the plan is on the
record while that happens, not to ask for anything ahead of it.
