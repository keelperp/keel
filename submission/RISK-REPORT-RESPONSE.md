# Flap Vault Interaction Risk Report

Generated: 2026-09-03 15:46:39 UTC

## Vault Security Rating
**Low**

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
### Finding 1: Trigger fee deducted after action is picked can invalidate the chosen deploy, wasting trigger fees
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** In the automatic settlement path, LeverVault.trigger() calls _pickAction() (which selects action 2 = deploy when pendingRevenue >= MIN_DEPLOY) BEFORE _schedule() deducts the trigger service fee from pendingRevenue. When pendingRevenue sits in the narrow band [MIN_DEPLOY, MIN_DEPLOY + fee), the fee deduction pushes pendingRevenue below MIN_DEPLOY, so settleSelf(2) -> _deploy() reverts with 'nothing to deploy yet'. The revert is caught by the try/catch, so the wake produces no work while a trigger fee (real BNB drawn from holder/project revenue) has already been spent. Because a picked action schedules the fast 5-minute cadence, the vault can repeat this for several wakes until pendingRevenue is drained below the threshold and it falls back to the idle cadence.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:trigger`
  - `src/flap/LeverVault.sol:_schedule`
  - `src/flap/LeverVault.sol:_deploy`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Confirmed exactly as described. `_pickAction` read `pendingRevenue` before `_schedule` spent the fee against it, so a balance in `[MIN_DEPLOY, MIN_DEPLOY + fee)` qualified for a deploy that the fee then starved. Fixed by having `_pickAction` reserve the fee before the threshold check, the same saturating way `_schedule` itself subtracts it — the number this function compares to `MIN_DEPLOY` is now the one `_deploy` will actually see once the fee is gone. Proven red by removing the reservation: a tax of exactly `MIN_DEPLOY` then has the selector pick a deploy the fee immediately starves. / 已修复：确认与描述完全一致。现在 `_pickAction` 在比较前就预留了手续费，用的是和 `_schedule` 一样的饱和减法。

### Finding 2: Levering-up rebalance folds the flash-loan buffer leftover (borrowed, debt-backed) into pendingRevenue and later into costBasis
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** When _rebalance takes the levering-up branch (`_build(0, p)`), the flash callback repays the pool and, whenever the swap output exceeds the amount owed, unwraps the surplus WBNB to idle BNB (`if (got > owed) IWNative(WBNB).withdraw(got - owed)`). That surplus originates from the 0.3% over-borrow and is offset by the extra USDT debt the vault just took on. _rebalance then measures this surplus as `rest` and, in the non-deleveraging branch, adds it to pendingRevenue without any costBasis adjustment. On the next _deploy, `costBasis += work` folds this borrowed surplus into costBasis as if it were principal. Since nav already reflects the offsetting debt, the surplus does not raise nav, so `_gain = nav - (costBasis + pendingRevenue)` is suppressed by the folded amount, delaying/reducing holder harvests.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_rebalance`
  - `src/flap/LeverVault.sol:pancakeV3FlashCallback`
  - `src/flap/LeverVault.sol:_deploy`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Confirmed, worked through in full first-principles terms rather than just accepted: a lever-up build's overall effect on `nav` is roughly a small NET LOSS (position equity falls by about the flash pool's 0.05% fee plus the 0.3% buffer, idle balance rises by the surplus net of the 0.01% swap fee — the two do not cancel, the operation costs a little, as expected). Folding the idle-balance portion into `pendingRevenue` without an offsetting `costBasis` decrease double-counted it: once implicitly (`nav` only rose by the small net amount, not the full surplus) and once explicitly (the same surplus added to `basis` again). Fixed by generalising the deleverage branch's existing treatment to both directions: `costBasis` now decreases by the same amount `pendingRevenue` gains on ANY rebalance, so `costBasis + pendingRevenue` is exactly invariant across the operation regardless of direction, and `_gain` moves only by what `nav` itself did — the real, small, fee-driven cost — nothing folded in on top. Covered by `test/LeverVaultLeverUpBasis.t.sol`, asserting the invariant on a genuinely under-leveraged live position; proven red by reverting the fix to the deleverage-only guard. / 已修复：把去杠杆分支已有的处理方式推广到两个方向，使 costBasis 与 pendingRevenue 在任何一次再平衡中都保持净额不变。


### Finding 3: Rebalance deleverage bounty is 0.3% of the deleveraged notional, not "0.3% of what it frees" as documented
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The README and the on-chain UI schema (vaultUISchema m[5] and vaultDataSchema) both describe rebalance as paying the caller "0.3% of what it frees" (支付所释放资金的 0.3%). In the leverage-up branch the code does compute `bounty = freed * REBALANCE_BOUNTY_BPS / BPS`, matching the doc. But in the deleverage branch a deleverage frees nothing by design (all redeemed BNB is spent on debt), so the code instead computes the bounty off the deleveraged notional: `owedBounty = excess * REBALANCE_BOUNTY_BPS / BPS * WAD / q.bnb`, then shrinks the position to free exactly that amount and pays `bounty = freed < owedBounty ? freed : owedBounty`. Here the bounty basis is `excess` (the entire amount removed from the position), not the BNB that actually leaves the vault.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_rebalance (deleveraging branch)`
  - `src/flap/LeverVault.sol:vaultUISchema (m[5] description)`
  - `src/flap/LeverVaultFactory.sol:vaultDataSchema`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Confirmed as a real basis-vs-wording gap, and it uncovered something the report did not claim: the lever-up branch could ALSO pay a small incidental bounty of its own, from the same flash-buffer leftover Finding 2 describes — contradicting the doc's own separate claim that levering up pays none. Fixed on both counts: the deleverage description now states the true basis precisely — 0.3% of the deleveraged notional, funded by an additional shrink sized to free that amount and capped by Venus's redeem limit — in both the on-chain schema (bilingual) and the README; and the lever-up branch's bounty is now hardcoded to zero rather than a rate applied to an incidental leftover, which makes "levering up pays no bounty" true unconditionally instead of true only when live pool slippage happened to exceed the buffer. Covered by the same test as Finding 2, which asserts the lever-up payout is exactly zero; proven red by restoring the rate-based computation. / 已修复，且发现了报告未提及的一点：加杠杆分支本会从同一处闪电贷余量意外付出一笔小额赏金，与我们自己「加杠杆不付赏金」的文档相矛盾——现已把该分支的赏金硬编码为 0。

---

## Fixes deployed / 修复部署

All three fixes are on chain, on BNB Chain (56) and BSC testnet (97) at identical addresses.

| Contract | Address | Runtime |
|---|---|---:|
| `LeverVaultFactory` (proxy — register this) | `0x9eFEd6EB5CcC8f015f908ce6760a9d713865989C` | 279 |
| `LeverFactoryBeacon` | `0x49E508D14fc99417d09259300d8B5f1A749d324F` | 785 |
| `LeverVaultFactory` (implementation) | `0x5D32A1d554F9EFdF8DE30fBB4340A451DFbA9946` | 7,745 |
| `LeverBeacon` | `0x7561A61e6C900808a48CDdb86779BCB80758E8B8` | 785 |
| `LeverVault` (implementation) | `0x759Ea1f363c4F743d2ad41B2d718d55429871e6c` | 23,092 |

| Chain | Block | Transaction |
|---|---:|---|
| BNB Chain, 56 | 119,845,863 | `0x5012b4a49f7d2f49482b616ff485e9bfa8531433b15ff7ede9a9aefbe4e83316` |
| BSC testnet, 97 | 128,990,344 | `0x5637915ee125994e9c33745138dcb909f06afa28c8a089940cab28277d04a556` |

The vault implementation's runtime is byte-identical to the local build. Every address this
replaces is listed under `retired` in `deployments/56.json` and must never be registered.

## Verification / 复现

```bash
bash scripts/test.sh     # 57 forge tests + 33 live-state assertions + 8 vault-UI checks
./submission/check       # deployed bytecode vs local build, both beacons' owners, wiring
```

Green as of this response. Plain `forge test` with no flags also exits 0 — 40 passed, 0 failed,
11 skipped (51 total), the skips being nine suites (and two individual tests) that need an
archive RPC BSC does not offer for free; see `submission/RULES.md` rule 006 for the list.
