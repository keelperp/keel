# Flap Vault Interaction Risk Report

Generated: 2026-09-05 04:52:57 UTC

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
### Finding 1: Harvest permanently bricked when the creator-configured `project` address cannot receive BNB (USER-RISK-DOS)
- **Severity:** Medium
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** In `_harvest`, holder dividends and the project payout are performed in a single atomic transaction. The vault deposits the 70% holder share into the dividend contract first, then executes `(bool sent,) = project.call{value: toProject}(""); require(sent, "...project transfer failed...")`. If the `project` address is a contract that cannot receive BNB (no payable receive/fallback, or one that reverts), `sent` is false and the entire `harvest()`/`_harvest()` call reverts, rolling back the holder dividend deposit as well. `project` is set once at vault creation from `vaultData` and has no setter, so a bad `project` address permanently disables all harvests: realized gain can never be distributed to holders and instead stays inside the leveraged Venus position, increasing liquidation exposure over time.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_harvest (project.call + require(sent))`
  - `src/flap/LeverVaultFactory.sol:newVault (project decoded from vaultData, no setter)`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):**
Confirmed exactly as described, and severity if anything understated: `project` has no setter,
so this was not a one-time failure but a permanent one -- every harvest after the first bad
attempt would revert identically, forever, with gain accumulating inside the leveraged position
and no path to ever recover it.

Fixed by reordering and redirecting rather than reverting. The project payout is now attempted
FIRST, before the dividend deposit (while the full `net` amount is still native BNB, so a failure
can be folded straight into `toHolders` without a second deposit call). If it succeeds,
`totalToProject` is credited as before. If it fails, the amount moves into `toHolders` instead --
so holders receive the full realised gain rather than losing the harvest to a project that cannot
be fixed -- and `ProjectPayoutFailed(uint256 amount)` is emitted so the failure is visible on
chain rather than silently absorbed.

```solidity
if (toProject > 0) {
    (bool sent,) = project.call{value: toProject}("");
    if (sent) {
        totalToProject += toProject;
    } else {
        emit ProjectPayoutFailed(toProject);
        toHolders += toProject;
        toProject = 0;
    }
}
```

Covered by `test/LeverVaultProjectPayoutFailure.t.sol`: a minimal contract with no payable
receive or fallback stands in for a broken `project`, asserting harvest still succeeds, the
broken address receives nothing, `totalToProject` never moves, holders receive the caller's
bounty's complement of the FULL gain (bounty plus the dividend contract's WBNB increase account
for the whole gain, nothing stranded), the event fires, and -- the report's own claim -- that
harvest keeps working across repeated cycles rather than bricking after the first attempt. Proven
red by reverting to the old `require(sent, ...)`: both tests then fail with the original revert
message.

已确认，严重程度只会被低估：`project` 没有 setter，所以这不是一次性失败，是永久性的——第一次失败之后
每一次 harvest 都会以同样的方式回滚，收益永远锁在仓位里，没有任何恢复路径。已修复：把项目方转账挪到分红
存入之前先尝试，失败就把这笔钱并入持有者份额而不是回滚整笔交易，并发出 `ProjectPayoutFailed` 事件保持
可见性。

---

## Fixes deployed / 修复部署

On chain, on BNB Chain (56) and BSC testnet (97) at identical addresses.

| Contract | Address | Runtime |
|---|---|---:|
| `LeverVaultFactory` (proxy — register this) | 0xbfFcBB69574774EeE211E7AfdBF41187c3278607 | 279 |
| `LeverFactoryBeacon` | 0xb36f6F95D07f137d54c4D6224063FfC5Fb789175 | 785 |
| `LeverVaultFactory` (implementation) | 0x5b8a4E2295297cf39635f6A8b43Db4c9a8d0Cb22 | 7,745 |
| `LeverBeacon` | 0x90b6Cba470Ba77CB1cb3d6455FB55D2681ea5b6D | 785 |
| `LeverVault` (implementation) | 0x4f6f9d028DFeCD11DEF6EB8e8862dae80C4A550b | 23,155 |

| Chain | Block | Transaction |
|---|---:|---|
| BNB Chain, 56 | 120,052,827 | 0xa64cdc43356136a25f24daa606901cda975744d04a86f2e84884f34390c7e613 |
| BSC testnet, 97 | 129,197,362 | 0x45e3fc83628f66e0cd5540ebf15289c296c2ba15f0f090537a686133b0dc5ed1 |

The vault implementation's runtime is byte-identical to the local build, and slightly SMALLER
than before (23,155 vs 23,193) -- the reordering removed as much as the new event and branch
added. Every address this replaces is listed under `retired` in `deployments/56.json` and must
never be registered.

## Verification / 复现

```bash
bash scripts/test.sh     # 63 forge tests + 33 live-state assertions + 8 vault-UI checks
./submission/check       # deployed bytecode vs local build, both beacons' owners, wiring
```

Green as of this response.
