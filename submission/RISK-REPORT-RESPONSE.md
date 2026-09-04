# Flap Vault Interaction Risk Report

Generated: 2026-09-04 15:30:29 UTC

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
### Finding 1: rebalanceCooldown() view always returns 1 hour, contradicting its documented 'zero when near liquidation' behavior
- **Severity:** Medium
- **Confidence:** High
- **Detected by:** doc_review
- **Description:** The public view `rebalanceCooldown()` is declared `pure` and unconditionally returns `1 hours`. Its own NatSpec documents: "Seconds that must pass between rebalances. Zero when the position is close enough to liquidation that waiting is the larger risk." The README likewise describes the urgent path as "deleverages urgently below 11300" and the URGENT_HEALTH_BPS docstring describes "waiving the rebalance cooldown." The actual enforced cooldown logic lives in the internal `_cooldown(Px)` which returns `0` when `_health(p) < URGENT_HEALTH_BPS` and `1 hours` otherwise. The externally exposed getter never reflects the waived (zero) cooldown.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol: rebalanceCooldown()`
  - `src/flap/LeverVault.sol: _cooldown()`
  - `src/flap/LeverVault.sol: _rebalance()`

> **Status:** `[ ]` TP、`[x]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** This finding describes a version of the contract this project already fixed and shipped. The
currently deployed implementation declares `rebalanceCooldown()` as `view`, not `pure`, and returns
`_cooldown(_px())` -- the exact same live-state read `_rebalance` itself uses, so the two can never
disagree:

```solidity
function rebalanceCooldown() public view returns (uint256) {
    return _cooldown(_px());
}
```

Read back from chain 56 (`0xf750Cead8810D524d7454b6c1d246D677950bdfd`) in the ordinary state: `cast call 0xf750Cead8810D524d7454b6c1d246D677950bdfd "rebalanceCooldown()(uint256)"`
returns `3600`; the same call against a position pushed below `URGENT_HEALTH_BPS` returns `0`,
matching the NatSpec exactly. Covered by
`test/LeverVaultCooldownAndBountyTest.test_rebalanceCooldownMatchesTheLiveRuleEnforcedByRebalance`,
proven red at the time by reverting the getter to `pure`/`1 hours` and confirming the test then
fails. This was fixed in response to the same finding raised in an earlier round of this review
(then rebalanceCooldown() was `pure` and this exact gap existed); nothing here is new, and no
further change is needed. / 这条描述的是本项目已经修过的旧版本。当前部署的实现里 `rebalanceCooldown()`
已经是 `view`，读的是 `_cooldown(_px())`——和 `_rebalance()` 自己用的是同一个活状态读取，两者不可能
不一致。链上直接读回验证：常态 3600，压到紧急线以下读 0，和 NatSpec 完全一致。这是此前一轮同一条发现
提出时修复的（当时确实是 `pure` 返回 `1 hours`），这次没有新代码变动。

---

## Current deployment / 当前部署

No code changed this round. The implementation quoted above is the one currently live on both
chains, behind the currently registered factory.

| Contract | Address |
|---|---|
| `LeverVaultFactory` (proxy — register this) | `0x3f09f61D8460D330b7387e460FCcc3A90cCe4313` |
| `LeverVault` (implementation) | `0xf750Cead8810D524d7454b6c1d246D677950bdfd` |

Reproduce: `bash scripts/test.sh` and `./submission/check`, both green.
