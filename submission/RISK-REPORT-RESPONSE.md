# Flap Vault Interaction Risk Report

Generated: 2026-09-03 14:53:13 UTC

## Vault Security Rating
**High**

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
### Finding 1: pancakeV3FlashCallback lacks flash-initiation guard, letting anyone force arbitrary leverage on the vault (COM-ACCESS-CONTROL)
- **Severity:** High
- **Confidence:** Medium
- **Detected by:** attacker_review
- **Description:** LeverVault.pancakeV3FlashCallback only checks `msg.sender == FLASH_POOL` and never verifies that the vault itself initiated the flash loan. Because PancakeSwap V3's `IV3Pool.flash(recipient, amount0, amount1, data)` lets any caller specify `recipient = vault` and arbitrary `data`, an attacker can invoke `FLASH_POOL.flash(vault, 0, amount1, attackerData)` and the pool will faithfully call `vault.pancakeV3FlashCallback(0, fee1, attackerData)`. The callback then executes the full leverage routine (`WBNB.withdraw`, `vBNB.mint`, `vUSDT.borrow`, `_swap`) using attacker-controlled `borrowed`, `pxBnb`, `pxUsdt`, with the ONLY invariant being `require(got >= owed)` for the flash repayment. Critically, the callback performs NO health check — the MIN_HEALTH_BPS (1.20) floor is enforced only by `_deploy`/`_rebalance` AFTER `_build` returns, not inside the callback. An attacker can therefore push the vault to Venus's maximum borrow (health ≈ 1.00, far below the 1.20 target) against flash-inflated and/or existing collateral, and can set `pxBnb/pxUsdt` so that the swap floor collapses to just `owed`, allowing a huge USDT borrow to be swapped with minimal slippage protection. Consequences: (1) the vault is forced into a near-liquidation leverage state that a small BNB price dip will liquidate, destroying holder value; (2) the attacker can sandwich the callback's USDT→WBNB swap (whose minOut is only `owed`) to extract the vault's swap slippage directly; (3) the vault is saddled with excess USDT debt. Attacker cost is only gas (the vault pays the flash fee out of the swapped proceeds).
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol: pancakeV3FlashCallback`
  - `src/flap/LeverVault.sol: _build (initiates flash without setting an in-flight guard)`

> **Status:** `[ ]` TP、`[x]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** The premise does not hold, and it fails at the one step that matters: PancakeSwap V3's `flash()` sends the borrowed tokens to `recipient`, but invokes the callback on `msg.sender` of the `flash()` call — the caller — not on `recipient`. Quoting the canonical PancakeV3Pool source: `if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1); ... IPancakeV3FlashCallback(msg.sender).pancakeV3FlashCallback(fee0, fee1, data);`. So `FLASH_POOL.flash(vault, 0, amount1, attackerData)` called by an attacker hands the vault free WBNB — but the pool calls the callback on the ATTACKER's own contract, not on `vault.pancakeV3FlashCallback`, which is never invoked. There is no scenario in which an external caller gets the pool to name the vault as `msg.sender` of a `flash()` call the vault itself did not make.

This is not an assertion we are asking you to trust. `test/LeverVaultFlashGuard.t.sol::test_attackerCallingFlashDirectlyNeverReachesTheVaultsCallback` calls `flash()` directly against the real live pool with the vault named as `recipient`, exactly as the finding describes, and shows the call reverts on a missing function on the *calling test contract* — never on the vault, whose balance does not move. We reproduced this both with and without the change below, to separate the fact from the fix: the attack fails to reach the vault either way.

We added a guard anyway, as defense in depth rather than a fix for a reachable path: a `_flashArmed` flag, set only inside `_build` immediately around the one legitimate `flash()` call it makes with vault-computed (never external) data, and checked inside `pancakeV3FlashCallback` alongside the existing `msg.sender == FLASH_POOL` check. It costs one SSTORE each way and makes the structural fact machine-checked instead of resting on an argument about a third party's source — worth doing given this is the second report to reason about flash-loan semantics, even though the conclusion here is the opposite of the last one. `test/LeverVaultFlashGuard.t.sol::test_theCallbackRefusesWhenNoFlashIsInFlight` proves the guard itself, via `vm.prank(FLASH_POOL)` with no flash in flight; proven red by removing the check, where it fails on a bare revert rather than our message, confirming the check is what makes it fail. / 前提站不住：PancakeSwap V3 的 `flash()` 把代币转给 `recipient`，但回调打给 `flash()` 的调用者本身，不是 `recipient`——攻击者直接调用只会让池子回调攻击者自己的合约，金库的 `pancakeV3FlashCallback` 根本不会被触发，已在真实主网池子上用测试复现验证。仍然加了一道防御性的门（`_flashArmed`），把这个结构性事实变成机器可验证的，而不是靠对第三方源码的论证。


### Finding 2: rebalanceCooldown() view returns a constant hour, contradicting the documented "zero when close to liquidation" behaviour
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The README (and the function's own NatSpec) states the rebalance cooldown is waived when the position is near liquidation: "URGENT_HEALTH_BPS ... Below this the vault deleverages immediately, waiving the rebalance cooldown", and rebalanceCooldown() is documented as "Seconds that must pass between rebalances. Zero when the position is close enough to liquidation that waiting is the larger risk." However the public getter `rebalanceCooldown()` is declared `pure` and unconditionally `return 1 hours;`. The cooldown that is actually enforced in `_rebalance` uses `_cooldown(p)`, which returns 0 when `_health(p) < URGENT_HEALTH_BPS`.
- **Vulnerable Code:**
  - `LeverVault.rebalanceCooldown()`
  - `LeverVault._cooldown()`
  - `LeverVault._rebalance()`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct as described, and already fixed the round before this report was generated — this report ran against a superseded build. `rebalanceCooldown()` now calls `_cooldown(_px())` directly, the exact function `_rebalance` uses, so there is one implementation of the rule rather than two that can drift. Read it back at `0x38f72bcdF1Fca500f2099b2636BbBB4fdE1c6AA1`: it returns 3600 ordinarily and 0 once `healthBps()` crosses `URGENT_HEALTH_BPS`, proven on a live fork by pushing the vault's own Venus debt past the line with `vm.store` rather than a mock. / 属实，且在这份报告生成之前的上一轮就已修复——本报告针对的是被取代的版本。链上可直接读回验证。


---

Finding 2 was already fixed. Finding 1 is FP for the reason above, and the `_flashArmed`
hardening it prompted is deployed regardless, on both chains at identical addresses. Register
`0x82d005723aF87A05cB4CffF0E5B50032DA068233`; the vault implementation is `0x38f72bcdF1Fca500f2099b2636BbBB4fdE1c6AA1`. Reproduce with
`bash scripts/test.sh` and `./submission/check`.
