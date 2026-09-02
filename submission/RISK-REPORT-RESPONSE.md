# Response — Flap Vault Interaction Risk Report

**Report generated:** 2026-09-02 08:09:19 UTC · **Vault Security Rating:** High
**Responded:** 2026-09-02 · **Contracts:** `src/flap/LeverVault.sol`, `src/flap/LeverVaultFactory.sol`

Both findings are **True Positive**. Both are fixed, deployed to BNB Chain and BSC testnet, and
covered by tests that were proven red before being trusted.

While writing the test for Finding 2 we found a **third defect that is not in this report and is
more severe than either of them**. It is disclosed in full below rather than shipped quietly.

两条发现均为**确认问题**，已全部修复并部署到主网与测试网，测试都先证红再采信。
在为 Finding 2 写测试的过程中，我们发现了**报告未提及、且比这两条都严重的第三个缺陷**，
下面完整披露，没有悄悄带过。

---

## Finding 1 — User-facing UI strings are English-only while error messages are bilingual

**Rule:** SYS-REQ-MULTILANG (rule 004, UI-02) · **Severity:** High · **Confidence:** High

### Status: [x] TP　[ ] FP　[ ] By Design　[ ] Acknowledged

**Reason / 说明**

Confirmed exactly as described. Rule 004 UI-02 reads:

> If the contract supports multiple languages, every user-facing string must include all
> languages explicitly, separated by ` / `.

All 27 `require` strings in `LeverVault` and all 15 in `LeverVaultFactory` were bilingual, which
is what establishes that the contract supports multiple languages. The strings a UI actually
renders were not. That is the violation, and the report lists every one of them correctly.

确认。27 条 `require` 是双语的，这本身就构成「合约支持多语言」，因此 UI 渲染的每个串都必须双语。

### What changed

All 13 UI-facing strings now carry both languages, separated by ` / `:

| Location | Strings |
|---|---:|
| `LeverVault.description()` | 1 |
| `LeverVault.vaultUISchema()` — method descriptions | 6 |
| `LeverVault.vaultUISchema()` — output field descriptions | 4 |
| `LeverVaultFactory.vaultDataSchema()` | 2 |

Verified by reading it back off chain rather than from the source:

```bash
cast call 0xCBf3f108A7E42B7a870f8B0729Ca88c165d9D421 \
  "vaultDataSchema()((string,(string,string,string,uint8)[],bool))" \
  --rpc-url https://bsc-dataseed.bnbchain.org
```

returns the description with its Chinese half attached. The same output is checked into
`submission/schema.txt`, which is regenerated from the chain rather than written by hand.

### Regression cover

`tools/check-docs.py` now fails if any assignment to `description`, `schema.description`, or a
`_one(...)` field description is missing the ` / ` separator. Implicit string concatenation is
joined first, so a literal split across source lines is judged as one string. Proven red by
reverting a single description to English-only.

---

## Finding 2 — Rebalance-down recycles position equity into pendingRevenue, permanently inflating costBasis

**Detected by:** attacker_review, rule_review · **Severity:** High · **Confidence:** High

### Status: [x] TP　[ ] FP　[ ] By Design　[ ] Acknowledged

**Reason / 说明**

Confirmed, and the mechanism in the report is accurate in every step. Restating it with the
detail that makes it load-bearing:

`_nav` counts idle balance (`src/flap/LeverVault.sol`, `_nav`: `... + idle`). So when
`_shrinkBy` pulls capital out of the Venus leg, NAV does not move — the BNB simply changes
form, from collateral to the vault's own balance. Booking it as `pendingRevenue` while leaving
`costBasis` alone therefore raises `costBasis + pendingRevenue` by the freed amount **out of
nothing**. `_deploy` then runs `costBasis += work` on that same BNB, and since `pendingRevenue`
is zeroed in the same call, the basis returns to where it was — but `costBasis` is now
permanently higher. Every later `_gain = nav - (costBasis + pendingRevenue)` sits lower by that
amount, and `harvest` reverts on `gain >= MIN_HARVEST` until NAV has grown past a basis that no
longer describes what was paid.

`costBasis` is written in exactly two places and is otherwise never reduced, which the report
also states correctly.

`_nav` 本来就含 idle 余额，所以去杠杆时 NAV 不变、basis 却凭空增加；再部署时 `costBasis += work`
把膨胀固化。此后 `_gain` 永久偏低，持有者拿不到分红。

### What changed

The deleveraging branch now **moves** the capital between the two accounts instead of adding to
one of them:

```solidity
if (rest > 0) {
    if (deleveraging) {
        costBasis = costBasis > rest ? costBasis - rest : 0;
    }
    pendingRevenue += rest;
}
```

Three things worth stating about the shape of this fix:

- **The bounty is deliberately not moved.** It genuinely left the vault, so it shows up as a
  fall in NAV — which is what a cost is. Moving it would have credited the vault for money it
  no longer holds.
- **Only the deleveraging branch is adjusted.** The other branch calls `_build(0, p)`, which
  consumes rather than frees; any residue there is borrowed capital, not basis.
- **`harvest` is untouched and its existing comment still holds.** Its freed BNB leaves the
  vault entirely — to the dividend contract, the project, and the caller — rather than being
  rebooked as pending revenue, so its basis genuinely should not move.

### Regression cover

`test/LeverVaultRebalanceBasis.t.sol`, two tests, asserting the identity rather than a
hard-coded number: whatever the unwind frees, `costBasis + pendingRevenue` must be unchanged,
and redeploying that capital must not grow it a second time. Proven red by removing the
`costBasis` adjustment.

---

## Not in the report: every deleverage was a no-op, by arithmetic

**Severity: Critical.** Found while building the test for Finding 2. Disclosed here because it
is strictly worse than either finding above, and because the tests that should have caught it
did not exist.

### The defect

`_maxRedeemableBnb` held the **redeem-then-repay** pass to `MIN_HEALTH_BPS`, meaning it only
returned a non-zero cap while `s > 1.5b`. But `rebalance` cannot trigger until leverage exceeds
`3x * 1.05`, and at that leverage `s = 1.4651b`. The two conditions are mutually exclusive:

| Trigger | Leverage | health | s/b | Cap |
|---|---:|---:|---:|---|
| `needsRebalance()` upper edge | 3.150x | 1.1721 | 1.4651 | **0** |
| Urgent rescue line | 3.424x | 1.1300 | 1.4125 | **0** |
| Cap opens at | 3.000x | 1.2000 | 1.5000 | > 0 |

So `_repayOnce` returned false on its first pass, the tail redeemed nothing, and the closing
`_health(...) >= MIN_HEALTH_BPS` check reverted the whole call. The first run of the new test
showed exactly that: leverage `3.151135534286093236` and health `11718` **identical before and
after** the rebalance.

The urgent rescue at health 1.13 was blocked the same way. **A position that drifted past the
band could not come back on any path** — not by rebalance, not by the automatic trigger, not by
anyone calling it manually. It could only wait for the price to recover, or be liquidated.

这是纯算术，不是偶发：`rebalance` 的触发线与赎回放行线互斥，因此每一次去杠杆都空转后回滚，
紧急救援同样被挡死。仓位一旦漂出区间就再也回不来。

### Why it survived until now

The two mechanisms that should have caught it both had a blind spot. The forge suites never
executed a deleverage end to end, and `FlapProbe` — which backs the 33 live-state assertions —
has `run`, `harvestPath`, `autoPath`, `triggerLoop` and `gasProfile`, but no rebalance path. An
unexercised path stayed broken.

### What changed

Repaying **raises** health: for `s > b`, `d/dx[(s-x)/(b-x)] > 0`. The redeem and the repay are
one atomic pass, so the dip between the two legs is never observable to a liquidator, and Venus
enforces its own limit on the redeem regardless. That leg now uses a floor of its own:

```solidity
uint256 public constant REPAY_FLOOR_BPS = 10_200;
```

The tail's **plain** redeem — which lowers health with nothing to offset it — keeps the strict
`MIN_HEALTH_BPS`. That split is deliberate: the existing comment about an early harvest freeing
3.88 BNB against a 0.99 BNB gain and leaving health at 1.003 describes the tail, and still
applies exactly where it was aimed.

### Regression cover

Both fixes are covered by the same suite, and the second was proven red by restoring the old
floor — which fails **both** tests, because with it the rebalance cannot run at all.

Getting a genuinely over-leveraged position to test against was the hard part, and is worth
recording:

- `_health` and `_leverage` both read `_positionUsd`, so mocking one moves the other and the
  closing health check can never pass. The unwind has to really deleverage.
- Cutting collateral (vBNB `accountTokens`, slot 14) also cuts what the unwind is permitted to
  redeem. That attempt left the position untouched at 3.151x.
- Raising debt (vUSDT `accountBorrows`, slot 16) keeps the collateral real, so repaying
  genuinely brings health back. Both slots were located by scanning for the slot whose value
  matches the getter, not assumed from the ABI.

---

## Deployment

All three fixes are on chain. Five contracts, identical addresses on BNB Chain (56) and BSC
testnet (97).

| Contract | Address | Runtime |
|---|---|---:|
| `LeverVaultFactory` (proxy — **register this**) | `0xCBf3f108A7E42B7a870f8B0729Ca88c165d9D421` | 279 |
| `LeverFactoryBeacon` | `0xb1145a8301ac72754B409aF1088cB1170500585D` | 785 |
| `LeverVaultFactory` (implementation) | `0xbA2F0a36EE66799e36f2bc3aD45aF8ACd5750cD2` | 7,397 |
| `LeverBeacon` | `0x396D1608AdA4F59775656Ff96823283d2B23d60d` | 785 |
| `LeverVault` (implementation) | `0x07785Ebb6482757739e176Ea5f761cc8B345a862` | 21,129 |

| Chain | Block | Transaction |
|---|---:|---|
| BNB Chain, 56 | 119,507,924 | `0xbf01a115aac5329c4356dda1b6821ba0706cbae17e6a431b62502ee64597f0ad` |
| BSC testnet, 97 | 128,651,782 | `0x0c1bed018907440b2f1306c482d673de6d4e044f8848b29f3b16c3e61316167c` |

Both beacons transfer ownership to the Flap Guardian inside their own constructors — the
deployer never holds upgrade authority for a single block. The vault implementation's runtime is
byte-identical to the local build, and the new constant reads back from the chain:

```bash
cast call 0x07785Ebb6482757739e176Ea5f761cc8B345a862 "REPAY_FLOOR_BPS()(uint256)" \
  --rpc-url https://bsc-dataseed.bnbchain.org      # -> 10200
```

The addresses this replaces are listed under `retired` in `deployments/56.json` and must never
be registered.

## Verification

```bash
bash scripts/test.sh          # 43 forge tests + 33 live-state assertions + 8 vault-UI checks
./submission/check            # deployed bytecode vs local build, both beacons' owners, wiring
```

Green as of this response. Plain `forge test` with no flags also exits 0; the suites that read a
Venus position are gated behind `KEEL_ARCHIVE=1` because BSC public nodes prune the state they
need.

## Still open

- `vault:check` reports one blocking rule, `manifest-binding/missing-test-token`. It needs a
  real 7777/8888 token bound in the manifest, and Flap's launcher creates that token through the
  VaultPortal at registration — so it can only close afterwards. Current output is in
  `submission/vault-check.json`.
- **SB-01**, the 30% project share, is disclosed in `submission/RULES.md` under rule 002 and
  awaits Flap's written ruling. We are not deciding it.
