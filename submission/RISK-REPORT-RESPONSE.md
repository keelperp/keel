# Flap Vault Interaction Risk Report

Generated: 2026-09-03 13:17:41 UTC

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
### Finding 1: rebalanceCooldown() view always returns 1 hour, contradicting its documented urgent-zero behavior
- **Severity:** Medium
- **Confidence:** High
- **Detected by:** doc_review
- **Description:** The public view `rebalanceCooldown()` is documented (its own NatSpec) as: "Seconds that must pass between rebalances. Zero when the position is close enough to liquidation that waiting is the larger risk." The README likewise describes waiving the cooldown in urgent situations. However the implementation is `function rebalanceCooldown() public pure returns (uint256) { return 1 hours; }` — it is `pure` and unconditionally returns 1 hour. The actual cooldown enforced in `_rebalance` uses the separate internal `_cooldown(p)`, which returns `0` when `_health(p) < URGENT_HEALTH_BPS`. Thus the public getter never reports the zero-cooldown urgent case it documents.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol: rebalanceCooldown()`
  - `src/flap/LeverVault.sol: _cooldown()`
> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct. Two functions computed the same thing and only one of them was ever actually asked — `_rebalance` calls `_cooldown(p)`, and `rebalanceCooldown()` existed only for a UI or a reviewer to read, `pure`, and wrong. Fixed by making the public getter call the exact function `_rebalance` calls, `_cooldown(_px())`, so it reads live Venus state and the two can never disagree again — there is only one implementation of the rule now, not two.

`test/LeverVaultCooldownAndBounty.t.sol` drives the vault's own debt below the urgent line (via `vm.store` on Venus's `accountBorrows`, not a mock) and asserts `rebalanceCooldown()` reads 0 there and 1 hour otherwise; proven red by reverting the getter to `pure`. Read it back at `0xC57c9D2ac2459e814Bc93C885C8D9F9E6d6Cd6A1`. / 属实。两个函数算的是同一件事，只有一个真正被 `_rebalance`调用。已改为公开视图直接调用 `_rebalance` 所用的同一个内部函数，两者不会再不一致。

### Finding 2: Harvest and rebalance exit swaps permit up to 300 bps slippage against the oracle, allowing recurring MEV extraction from the treasury (COM-MEV-SANDWICH)
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** The unwind path (_repayOnce -> _sellBnb/_buyBnb -> _swap) floors output at MAX_SWAP_SLIP_BPS = 300 bps below the Venus oracle price. Because harvest(), rebalance() and the automatic settlement path are permissionless and their timing is publicly observable, a searcher can sandwich the WBNB/USDT swaps and push the realized price down to the 3% floor on every settlement that involves a swap, extracting value from the vault (less USDT recovered per BNB sold, leaving the position more leveraged / freeing less value for holders).
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_floor`
  - `src/flap/LeverVault.sol:_repayOnce`
  - `src/flap/LeverVault.sol:_sellBnb`
  - `src/flap/LeverVault.sol:_buyBnb`
> **Status:** `[ ]` TP、`[ ]` FP、`[ ]` By Design、`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** The mechanism is real, we said so first, and this is the same disclosure standing — nothing new to add mechanically. `submission/RULES.md` under rule 003: "3% is deliberately loose, and sandwiching is not prevented... an attack that stays inside the band still profits, and the floor only caps how much it can take." The floor is proven red rather than assumed: demanding 20% above the oracle instead of 3% makes the unwind revert and drops the 33 live-state assertions to 12, because a floor tight enough to catch every sandwich also stops the vault deleveraging in exactly the fast market where deleveraging matters most.

Tightening it is a real option and we are not closing the door on it — 300 bps was chosen to survive legitimate volatility, not calibrated against measured MEV activity on this pair. If Flap has a number in mind, or wants us to measure realised extraction on the live pool before deciding, say so and we will. Absent that, our own judgment is that a slippage floor sized correctly stops griefing (an attacker forcing settlement at an arbitrarily bad price) without being confused for a tool that removes sandwiching, which no static floor can do. / 机制属实，与我们此前的披露一致，这次没有新增内容。3% 是为了不挡住合法波动而选的，不是按实测 MEV 活动校准的——如果 Flap 有具体数字，或希望我们先实测再定，我们照做。

### Finding 3: Rebalance lever-up path pays essentially no bounty, contradicting the documented "each pays a fixed bounty"
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The README states: "The three working functions — deployPending, harvest, rebalance — are permissionless and each pays a fixed bounty to whoever calls it", and the UI schema describes rebalance as "pays 0.3% of what it frees." In `_rebalance`, when the position is UNDER-leveraged (leverage below the band), the code runs `_build(0, p)`, which borrows more USDT and mints more vBNB and frees no BNB. The bounty for the non-deleveraging branch is then `bounty = freed * REBALANCE_BOUNTY_BPS / BPS`, where `freed = address(this).balance - bnbBefore ≈ 0`. Hence a caller who performs a lever-up rebalance receives approximately zero bounty, unlike the deleverage branch which deliberately shrinks the position to fund the caller.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol: _rebalance()`
  - `src/flap/LeverVault.sol: vaultUISchema() (m[5] rebalance description)`
> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct that the README overclaimed. The schema you also cite was already accurate as written — "pays 0.3% of what it frees" is literally true when what it frees is zero — but the README's "each pays a fixed bounty to whoever calls it" was not qualified, and left the reasonable impression that lever-up pays too.

We are not adding a bounty to the lever-up branch, because there is nothing for it to be paid out of without inventing a new source, and it is not needed: lever-up means leverage is below target, which is the safe direction, so there is no urgency requiring a paid caller to race the scheduled wake. The automatic path reaches it regardless of any bounty. So documentation changed rather than behavior — both the README and the on-chain schema now say the bounty is real only on the deleveraging half, in both languages, and `submission/RULES.md`'s rule 003 row was corrected the same way since it carried the same overclaim.

`test/LeverVaultCooldownAndBounty.t.sol` asserts the new schema string discloses the lever-up case; proven red by reverting it to the old wording. / 属实，README 表述过头，schema 本身没错。没有给加杠杆分支加赏金——没有可付的资金来源，也不需要，因为加杠杆是安全方向，不急，自动路径迟早会做。已改的是文案：README、链上 schema、submission/RULES.md 三处同步更正。

---

Finding 1 is fixed and deployed; findings 2 and 3 are, respectively, a standing disclosure (unchanged)
and a documentation correction (fixed on chain, in the README, and in `submission/RULES.md`). All
three are on both chains at identical addresses. Register `0x2559DD277E5a8E2f6d8594Deded3eD1025e6402C`; the vault implementation
carrying these fixes is `0xC57c9D2ac2459e814Bc93C885C8D9F9E6d6Cd6A1`. Reproduce with `bash scripts/test.sh` and
`./submission/check`.
