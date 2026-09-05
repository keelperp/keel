# Flap Vault Interaction Risk Report

Generated: 2026-09-04 16:30:31 UTC

## Vault Security Rating
**Medium**

## Status Guide / 状态说明

Please review each finding below and mark its status. / 请审阅以下每条发现并标记状态。

| Status | Meaning / 含义 |
|:---:|---|
| **TP** | True Positive — This is a real issue, we will fix it. / 确认问题，我们会修复。 |
| **FP** | False Positive — This is not a real issue, the analysis is incorrect. / 误报，分析有误。 |
| **By Design** | This is intentional behavior, not a bug. / 这是设计如此，非缺陷。 |
| **Acknowledged** | The issue is real but the impact is acceptable, will not fix. / 问题确实存在，但影响在可接受范围内，不修复。 |

Mark by replacing `[ ]` with `[x]`. If FP, By Design, or Acknowledged, please write a brief reason. / 在对应选项的 `[ ]` 中填入 `x` 标记。如标记 FP、By Design 或 Acknowledged，请简要说明理由。

---

## Risk Findings
### Finding 1: Undeployed BNB tracking (pendingRevenue) can desync from the actual idle balance, causing _gain/harvest to misclassify non-gain BNB as harvestable and prematurely de-lever the position (COM-PASSIVE-SYNC-GAP)
- **Severity:** Medium
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** `_gain` computes `nav - (costBasis + pendingRevenue)`, where `nav` counts the vault's entire native balance (`address(this).balance`) but the offsetting term only subtracts `pendingRevenue`. `pendingRevenue` is updated exclusively through `receive()` accounting and the internal basis-neutral adjustments. Any native BNB that enters the vault without incrementing `pendingRevenue` (e.g. BNB force-sent via selfdestruct, or any donation that bypasses `receive()`'s accounting) increases `nav`, and therefore `_gain`, without a matching increase in the basis. A subsequent `harvest()` then treats that untracked BNB as position gain: `_shrinkBy(gain, p)` unwinds a larger fraction of the leveraged Venus position than the true unrealized gain, distributing principal/donated funds to holders/project and leaving the surplus BNB stranded as idle balance that `deployPending()` will never redeploy (it reads `pendingRevenue`, not the balance).
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_gain`
  - `src/flap/LeverVault.sol:_harvest`
  - `src/flap/LeverVault.sol:receive`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):**
Confirmed, and worked through to the root rather than patched at the surface. The mechanism is
precise: `_shrinkBy(gain, p)` frees position-only equity, so the remaining position value after a
harvest lands at `costBasis + pendingRevenue - idle` -- exactly `costBasis` only while
`idle == pendingRevenue`. Every internal source of idle balance (the flash-repay swap's own
buffer in both `_deploy` and `_rebalance`, and `_deleverBy`'s WBNB dust) was already made to
maintain that invariant in earlier rounds of this review. `selfdestruct` cannot: it credits a
balance with no call, no `receive()`, and no hook any contract can write, so no amount of
tracking on our side could ever bring it into `pendingRevenue`. That made this the wrong place to
keep patching -- the invariant `_gain` depended on is not something a contract can universally
enforce against an external sender.

Fixed at the root instead: `_gain(p)` is rewritten to compare position-only equity
(`_nav(p) - address(this).balance`, the same figure `_shrinkBy` itself targets) directly against
`costBasis`, dropping `pendingRevenue` from the comparison entirely.

```solidity
function _gain(Px memory p) internal view returns (uint256) {
    uint256 posEquity = _nav(p) - address(this).balance;
    return posEquity > costBasis ? posEquity - costBasis : 0;
}
```

This makes `_gain` immune to idle-balance mismatches from any source -- present, or a fifth one
neither report has found yet -- rather than requiring a matching fix at each new one. It changes
nothing about the ordinary case: `pendingRevenue`-tracked tax revenue sits as idle balance either
way, and was already excluded from the old formula's `nav - basis` by the `pendingRevenue`
subtraction it performed; the new formula excludes it identically, by never including idle
balance in the comparison at all. `pendingRevenue`'s own bookkeeping (accumulating tax, funding
`_deploy`, the trigger-fee draw) is untouched -- only how `_gain` decides whether there is
anything to harvest changed.

Covered by `test/LeverVaultDonationImmunity.t.sol`: a `vm.deal` credit reproduces exactly what a
`selfdestruct` delivers (balance rises, no call, `pendingRevenue` untouched), asserting the
donation is not read as gain, and that a harvest triggered by real appreciation afterward leaves
position equity at or above `costBasis` despite the donation sitting in the balance at the same
time. Proven red by reverting `_gain` to the old formula: the donation showed up in
`unrealisedGain()` at essentially its full value.

已确认，并且从根子上解决而不是逐个补洞。`selfdestruct` 强制转账没有任何回调，合约写不出能拦截它的钩子，
所以继续在 `pendingRevenue` 里追踪是治标不治本的方向。改为让 `_gain` 只比较仓位自身价值和 `costBasis`，
完全脱离 `pendingRevenue`/闲置余额——这样无论未来还有第几种未追踪的余额来源，都不会再影响 gain 的判断。

---

## Fixes deployed / 修复部署

On chain, on BNB Chain (56) and BSC testnet (97) at identical addresses.

| Contract | Address | Runtime |
|---|---|---:|
| `LeverVaultFactory` (proxy — register this) | 0x487Bd18860c321b6Fa01e9F95B3F9BF878c4939B | 279 |
| `LeverFactoryBeacon` | 0x01595F8AD2737a78AAAcEd9C14264c70799B418E | 785 |
| `LeverVaultFactory` (implementation) | 0xfd439F46D9D842D4a84c94a32D1BF8Ce57Dc39e9 | 7,745 |
| `LeverBeacon` | 0x2d37B394C24aBa34b25A514817E8380b8b58E29E | 785 |
| `LeverVault` (implementation) | 0x68e4317070Cf99cC7462741191DFcCAE75c73853 | 23,193 |

| Chain | Block | Transaction |
|---|---:|---|
| BNB Chain, 56 | 120,046,230 | 0xd99db9925d954084a3d00af938dcd45280a7c6020d58ca6dbe49ecc2e356cb37 |
| BSC testnet, 97 | 129,190,762 | 0x1e5fc44955176283b14c95abf0a498280f9253150d9674be2b0b64d148a9fa1b |

The vault implementation's runtime is byte-identical to the local build (unchanged at 23,193
bytes -- the rewrite removed as much as it added). Every address this replaces is listed under
`retired` in `deployments/56.json` and must never be registered.

## Verification / 复现

```bash
bash scripts/test.sh     # 61 forge tests + 33 live-state assertions + 8 vault-UI checks
./submission/check       # deployed bytecode vs local build, both beacons' owners, wiring
```

Green as of this response.
