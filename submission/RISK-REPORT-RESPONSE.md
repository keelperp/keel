# Flap Vault Interaction Risk Report

Generated: 2026-09-03 12:27:11 UTC

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
### Finding 1: Rebalance deleverage bounty applies REBALANCE_BOUNTY_BPS twice, underpaying keepers and churning the position
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** In the deleverage branch of _rebalance, the vault manufactures freeable BNB by calling _shrinkBy with an amount that is already scaled by REBALANCE_BOUNTY_BPS (`excess * REBALANCE_BOUNTY_BPS / BPS * WAD / q.bnb`). The resulting freed amount is therefore ~0.3% of `excess`. The generic line `bounty = freed * REBALANCE_BOUNTY_BPS / BPS` then scales this down by another factor of 0.3%, so the caller actually receives ~0.0009% of `excess` instead of the intended 0.3% bounty on the repositioned amount. The remainder of the manufactured shrink (~0.3% of excess) is returned to pendingRevenue and later re-levered, incurring flash-loan fees and swap slippage for no benefit. Intended: pay the keeper a 0.3% bounty for a deleverage rebalance. Actual: keeper is paid ~333x less and the treasury needlessly churns capital out of and back into the leveraged position.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_rebalance (deleverage bounty shrink and bounty = freed * REBALANCE_BOUNTY_BPS / BPS)`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct in every part, including the ~333x. This one is ours: it was introduced by the fix for Finding 5 of the previous report, when the deleverage branch stopped freeing anything on its own and a bounty shrink was added to pay the caller. The shrink was sized to the bounty, so what it frees IS the bounty — and sending that through the generic rate applied 0.3% a second time.

Fixed by deciding the bounty per branch instead of running both through one line. The deleverage branch now remembers what it asked the shrink for and pays exactly that, capped at what the shrink actually managed (the redeem cap can bind and leave it short). The build branch keeps the generic rate, where it is still right. Measured on a fork before and after: with the defect the caller received 0.00022 BNB while 0.00727 BNB went back to `pendingRevenue`; after, the caller gets the shrink and the queue does not.

`test/LeverVaultSelectorBounty.t.sol` pins both halves — that the bounty is not discounted twice, and that the shrink reaches the caller rather than the queue — and was proven red by restoring the double rate. / 完全属实，包括那个约 333 倍。这是我们上一轮修 Finding 5 时引入的：去杠杆分支改成不再自行释放资金后，加了一次「专为赏金」的 shrink，而它释放的就是赏金本身，再过一遍通用费率等于又乘了一次 0.3%。已改为分支各自决定赏金。实测：修复前调用者拿 0.00022 BNB、队列回流 0.00727 BNB；修复后全部归调用者。

### Finding 2: Harvest can be perpetually selected and revert when the dividend contract has no eligible holders, starving routine rebalance in the automatic path
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** _harvest requires the dividend contract to actually accept the WBNB deposit (`require(WBNB.balanceOf(this) <= wbnbHeld)`). When the token's dividend contract has zero total shares (e.g., all holders are below minimumShareBalance), Dividend.deposit returns without pulling tokens and this require reverts, blocking harvest. In the automatic settlement path, _pickAction prioritises harvest (action 3) above ordinary rebalance (action 4) whenever gain >= MIN_HARVEST and BNB cash is available, without checking that the dividend can accept the deposit. As a result, while gain has accrued but there are no eligible holders, every automatic wake selects harvest, reverts inside the try/catch, and a (non-urgent) rebalance that would otherwise be performed is never reached via automation. Urgent rescues (action 1) and manual rebalance() remain available, so funds are not locked.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_pickAction (harvest selected before rebalance without dividend-servability check)`
  - `src/flap/LeverVault.sol:_harvest (revert when dividend does not take WBNB)`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct, and also ours: the requirement in `_harvest` came from the fix for Finding 2 of the previous report, and the selector was not taught about it. It is the same defect the selector already carried once — an action that cannot succeed staying selected and starving one that can — which we fixed for the rescue path and did not generalise. Your closing sentence is right and worth keeping in the record: funds are not locked, urgent rescues and manual calls are unaffected.

Fixed by asking before choosing. `_pickAction` now calls `_dividendCanTake()`, which reads `totalShares()` on the token's dividend contract and excludes harvest when it is zero, exactly as the Venus `getCash` checks above it exclude actions the market cannot serve. Both reads are wrapped in `try` so a token whose dividend contract is missing or reverting cannot brick the selector for every other action — that failure mode would be worse than the one being fixed.

`test/LeverVaultSelectorBounty.t.sol` mocks `totalShares() == 0` and asserts the selector does not return 3; proven red by removing the check. / 属实，同样是我们上一轮修 Finding 2 时引入的：`_harvest` 加了要求，选择器没被同步告知。这与选择器此前那个「选中一个跑不了的动作、饿死能跑的动作」是同一个缺陷，我们当时只修了救援那条没有推广。现已在选中前先问分红合约有没有人可付，两处读取都包在 try 里，避免分红合约异常反而拖垮整个选择器。


### Finding 3: README promises settlement 'every five minutes'; code backs off to hourly when idle
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The README states unconditionally that the vault 'settles every five minutes' and that 'Flap's Trigger Service calls the automatic path every five minutes.' The code, however, defines both TRIGGER_INTERVAL = 5 minutes and IDLE_INTERVAL = 1 hour. In trigger(), _schedule(action == 0 ? IDLE_INTERVAL : TRIGGER_INTERVAL) reschedules the next wake an hour out whenever the previous wake found no work (action 0). The README never mentions this idle back-off (only the in-code vaultUISchema/vaultDataSchema does).
- **Vulnerable Code:**
  - `LeverVault.trigger(uint256)`
  - `LeverVault._schedule(uint64)`
  - `LeverVault.IDLE_INTERVAL / TRIGGER_INTERVAL`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct, and your parenthetical is the sharp part: the on-chain schemas were fixed for this in the previous round and the README was not. We reported that round as having corrected it "on chain and in the README" — the on-chain half was done, the README half was not, and stating both is what let it through. Both sentences now say it: five minutes while there is work, hourly after a wake that finds nothing, and that this is a floor on responsiveness rather than a cap, since the three working functions are permissionless and paid and need no wake. / 属实，而且括号里那句最要紧：链上 schema 上一轮改了、README 没改，而我们当时报告成「链上和 README 都改了」——两处一起说，恰恰是它蒙混过关的原因。现已改正，并注明这只是响应下限不是上限。

### Finding 4: Rebalance closing check does not enforce the documented 12000 health floor
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The README promises the vault 'holds a MIN_HEALTH_BPS floor of 12000 (liquidated only by a 16.7% move).' The deploy and harvest paths enforce this strictly (require(_health(p) >= MIN_HEALTH_BPS)). The rebalance path instead accepts require(healthAfter >= MIN_HEALTH_BPS || healthAfter > healthBefore), i.e. it will complete and leave the position below 12000 health as long as health merely improved.
- **Vulnerable Code:**
  - `LeverVault._rebalance(address)`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** The discrepancy is real and the README was wrong to state the floor without the exception. The code is what we intend, though, so the README changed rather than the check — here is the reasoning, and if you disagree we will change the check instead.

At the 3x target the health floor is `0.8 x 3/2 = 1.2000` **exactly**: `TARGET_LEVERAGE`, `MIN_HEALTH_BPS` and Venus's 80% collateral factor are coincident, not independent. So a deleverage that lands precisely on its own target sits precisely on the line, and any swap friction puts it a hair under. An absolute check there reverts the very move it exists to encourage — we measured that: before this was changed, every deleverage and every urgent rescue reverted on the closing check, which is what the previous report's Finding 5 turned out to be underneath. The same check would also revert a deep rescue climbing from 1.05 to 1.15, which is a large improvement and exactly what should be allowed to complete.

So rebalance requires health to have **risen**, keeping the absolute floor as the other way to pass. Deploy and harvest are unchanged and still enforce 12000 strictly — the difference is that those two put the position INTO a state, while rebalance is the path that gets it OUT of a bad one. The README now says this in the paragraph that makes the 12000 promise. / 差异属实，README 不该不加限定地承诺这个下限。但代码是我们想要的形态，所以改的是 README——理由如下，若你们不同意我们就改代码。3 倍杠杆下健康度恰好等于下限本身（0.8×3/2 = 1.2000），三个常量是重合的不是独立的；落在目标上就压在线上，任何摩擦都会掉下去。绝对判定会回滚它本该鼓励的动作——上一版 Finding 5 底下的真正原因正是这个。而且它同样会回滚一次从 1.05 爬到 1.15 的深度救援。建仓和结算仍然严格执行 12000；差别在于那两条是「进入」状态，再平衡是「脱离」坏状态的那条路。


---

All four are fixed and deployed on BNB Chain (56) and BSC testnet (97) at identical addresses.
Register `0x1B4304227D4090E2418ADd6bdB8AA43395cBf69e`; the vault implementation carrying these fixes is
`0x471f00F9D9cfAc8910a20C95770Dd7706Cb09D9f`. Findings 1 and 2 were regressions from the previous round's
fixes and now carry tests that were proven red; findings 3 and 4 were README claims the code had
outgrown. Reproduce with `bash scripts/test.sh` and `./submission/check`.
