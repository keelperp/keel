# Flap Vault Interaction Risk Report

Generated: 2026-09-03 09:32:59 UTC

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
### Finding 1: Multi-language intent established by bilingual require messages, but description() and UI schema strings are English-only (SYS-REQ-MULTILANG)
- **Severity:** High
- **Confidence:** High
- **Detected by:** rule_review
- **Description:** The contract establishes multi-language (English / Chinese) intent throughout its require/revert messages using the ` / ` separator, but all user-facing strings returned by description(), vaultUISchema(), and the factory's vaultDataSchema() are single-language English only. Under SYS-REQ-MULTILANG, once multi-language evidence exists, every user-facing string must be bilingual. The English-only description and UI-schema descriptions are non-compliant.
- **Vulnerable Code:**
  - `LeverVault.description(): "Trading tax becomes a leveraged BNB position the vault holds on Venus itself. The treasury moves with the market when nobody is trading, and its gain is paid to holders through the token's dividend contract. No keeper, no published NAV, no pause."`
  - `LeverVault.vaultUISchema(): schema.description (returns description() — English only)`
  - `LeverVault.vaultUISchema(): "Treasury value in BNB, read straight from Venus."`
  - `LeverVault.vaultUISchema(): "Treasury value in wei"`
  - `LeverVault.vaultUISchema(): "Live BNB exposure over net value, 1e18-scaled."`
  - `LeverVault.vaultUISchema(): "3e18 means 3x"`
  - `LeverVault.vaultUISchema(): "Collateral x factor over debt, in bps. Venus liquidates at 10000."`
  - `LeverVault.vaultUISchema(): "12000 means liquidated only by a 16.7% move"`
  - `LeverVault.vaultUISchema(): "Turn accumulated tax into position. Anyone may call; pays 0.25%."`
  - `LeverVault.vaultUISchema(): "BNB paid to the caller"`
  - `LeverVault.vaultUISchema(): "Distribute the position's gain: 70% to holders as WBNB dividends, 30% to the project. Anyone may call; pays 0.5% to the caller."`
  - `LeverVault.vaultUISchema(): "Push leverage back inside the band. Anyone may call; pays 0.3% of what it frees."`
  - `LeverVaultFactory.vaultDataSchema(): "Trading tax is levered into a 3x BNB long the vault holds on Venus. Gains are settled automatically every 5 minutes: 70% to holders as WBNB dividends, 30% to the project."`
  - `LeverVaultFactory.vaultDataSchema(): "Receives 30% of every harvest. Fixed at creation; the vault has no setter."`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Agreed, and already fixed — this report was generated against a build that had been superseded. All 13 strings carry both languages now. Verify on chain rather than in source: `cast call 0x4F6f3D2E103A90599B994623B058BF8C984Adc4B "description()(string)"` returns 60 Chinese characters after a ` / ` separator, and `cast call 0x62D1C54CeA0a03096741dc72e51E7a4c5Ec0ACFA "vaultDataSchema()((string,(string,string,string,uint8)[],bool))"` likewise. `tools/check-docs.py` fails the build if any `description`, `schema.description` or field description lacks the separator, including across implicit concatenation split over source lines; proven red by reverting one string. / 已修复。本报告针对的是已被取代的版本；13 条串全部双语，链上可直接读回验证，并已加防回退的门。

### Finding 2: Unchecked return value of IDividend.deposit in _harvest leaves accounting and holder funds inconsistent (COM-EXTERNAL-CALL-FAILURE)
- **Severity:** Medium
- **Confidence:** Medium
- **Detected by:** rule_review
- **Description:** In LeverVault._harvest, the vault wraps the holders' share into WBNB, approves the dividend contract, and calls IDividend(div).deposit(toHolders) without checking its boolean return value. The Flap Dividend contract returns false (and pulls no tokens) when totalShares == 0 (e.g. all holders excluded or below minimumShareBalance). When that happens, the WBNB is NOT transferred to the dividend contract, yet the vault still increments totalHarvested as if holders were paid, still pays the project its 30% and the caller's bounty, and the harvest succeeds. The undistributed WBNB remains in the vault and is re-wrapped to BNB and re-counted as 'freed' by _shrinkBy on the next harvest, at which point the project again skims its PROJECT_SHARE_BPS (30%) from what was originally the holders' share — progressively diverting holder funds to the project while the harvest returns success.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_harvest (IDividend(div).deposit(toHolders) call)`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Agreed, and already fixed before this report was generated. One correction to the description, which does not change the verdict: our `IDividend` declares `deposit(uint256)` with **no return value**, so there was no boolean to check — the defect was real but not reachable by checking a return. `_harvest` now records the vault's WBNB balance before wrapping and requires it to be no higher afterwards, which does not depend on the callee's interface at all. If the dividend contract takes nothing, the whole harvest reverts and the gain stays in the position for the next attempt, so none of the downstream consequences you traced can begin: `totalHarvested` is not incremented, the project is not paid, and there is no undistributed WBNB to be re-counted on a later harvest. Read it back at `0x4F6f3D2E103A90599B994623B058BF8C984Adc4B`. / 已在本报告生成前修复。更正一处：接口把 `deposit` 声明为无返回值，字面上没有可检查的返回值；改为余额差校验，未收取即整笔回滚，你描述的后续连锁因此无法开始。


### Finding 3: Rebalance-freed equity is double-counted in costBasis, permanently suppressing harvests to holders
- **Severity:** Medium
- **Confidence:** Medium
- **Detected by:** attacker_review
- **Description:** In _rebalance(), BNB freed by deleveraging is added to pendingRevenue (`if (rest > 0) pendingRevenue += rest;`). That freed BNB is the vault's own equity pulled out of the Venus position — it was already recorded in costBasis when it was deployed, and costBasis is never decremented when the equity leaves the position during a rebalance. When _deploy() later consumes that pendingRevenue it runs `costBasis += work`, counting the same equity in costBasis a second time. Because `basis = costBasis + pendingRevenue` is the reference used by _gain() (`_gain = nav - (costBasis + pendingRevenue)`), each down-move rebalance→deploy cycle permanently inflates basis by roughly the freed equity. Since real gains are measured against this inflated basis, unrealisedGain() and harvest() progressively understate the position's gain, distributing less (eventually nothing) to holders and the project. Value is not lost from the vault but accumulates undistributed in the leveraged position, and costBasis grows monotonically with normal market volatility until harvest can never trigger. Intended: basis reflects only the true principal committed; actual: basis grows by every rebalance-freed amount; consequence: holders/project are under-paid or never paid.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_rebalance (pendingRevenue += rest)`
  - `src/flap/LeverVault.sol:_deploy (costBasis += work)`
  - `src/flap/LeverVault.sol:_gain`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Agreed in every step, and already fixed before this report was generated. The deleveraging branch now moves the capital between the two accounts rather than adding to one: `costBasis` falls by the same amount `pendingRevenue` rises, so `basis` is unchanged across a rebalance and the later `costBasis += work` in `_deploy` restores it exactly. The bounty is deliberately excluded from that move — it genuinely left the vault, so it shows up as a fall in NAV, which is what a cost is. `harvest` is untouched, because its freed BNB leaves the vault entirely rather than being rebooked. `test/LeverVaultRebalanceBasis.t.sol` asserts the identity rather than a number, and was proven red by removing the adjustment. / 已在本报告生成前修复：去杠杆改为在两个账户之间搬运，`basis` 跨再平衡保持不变。

### Finding 4: Build-path USDT→WBNB swap has no oracle floor, allowing MEV extraction up to the flash buffer (COM-MEV-SANDWICH)
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** pancakeV3FlashCallback() performs `_swap(USDT, WBNB, usdtNeeded, 0)` with amountOutMinimum = 0, relying only on `require(got >= owed)` to bound the swap. usdtNeeded is sized with a 0.3% buffer over the flash repayment (`owed * pxBnb / pxUsdt * 1003/1000`). The require only guarantees the flash loan is repaid, not that the vault received fair value for the USDT debt it took on. A searcher can sandwich the build swap and push the output down to just above `owed`, capturing up to the ~0.3% buffer (the surplus that would otherwise be unwrapped back to the vault as idle BNB) and leaving the vault carrying slightly more USDT debt per BNB of collateral than intended. The exit swaps (_sellBnb/_buyBnb) are protected by an explicit oracle floor (_floor with MAX_SWAP_SLIP_BPS); the build swap is not, creating an asymmetry the exit-path fix did not cover.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:pancakeV3FlashCallback (_swap(USDT, WBNB, usdtNeeded, 0))`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct, and the comment defending the old line was wrong in a way worth stating: it claimed `require(got >= owed)` is "strictly tighter" than an oracle floor. Valued at the oracle, the exit path's `MAX_SWAP_SLIP_BPS = 300` puts the floor at `1.003 x 0.97 = 0.973 x owed` — **below** the repayment bound, so simply reusing it here would have constrained nothing. That asymmetry is why the exit-path fix did not extend.

Fixed with a floor sized against the quantity actually at risk. `MAX_BUILD_SLIP_BPS = 25` is a separate constant from the exit's 300, and two facts pin it. It must stay under 0.299%, because at or above that the floor falls below `owed` and stops binding. And it must clear real slippage on the venue: measured against the Venus oracle on the 0.01% WBNB/USDT tier at the live pool (4,935 WBNB / 8.26M USDT), a USDT→WBNB swap loses 0.109% at 6,000 USDT, 0.131% at 30,000 and 0.215% at 120,000. 25 bps sits above the largest of those and below the ceiling.

Worth recording because it changed our answer: our first attempt was "keep half the buffer", which allowed only 0.1495% of slippage and would have reverted any build above roughly 50,000 USDT — a fix that stops tax becoming a position is worse than the leak it prevents. The floor caps a sandwich at 0.25% of the repayment rather than the full 0.3%; that ceiling is set by the buffer itself, and we are not claiming more. Read `MAX_BUILD_SLIP_BPS()` at `0x4F6f3D2E103A90599B994623B058BF8C984Adc4B`. / 属实，且旧注释的辩护是错的：exit 的 3% 下界折算后是 0.973×owed，低于还款约束，套用过来不约束任何东西。新增独立常量 25 bps —— 上限受 buffer 限制必须 <0.299%，下限受实测滑点限制（6,000/30,000/120,000 USDT 分别为 0.109%/0.131%/0.215%）。第一版「保住一半 buffer」只容 0.1495%，会让 5 万 USDT 以上的建仓直接失败。

An adversarial review of the fix itself surfaced something worth passing on, because it bears on
how much this is really buying. Adding a floor of T on top of a buffer of b is, to the last digit,
the same protection as shrinking the buffer to `b x (1-T)` and keeping no floor at all: both admit
the same worst-case extraction and revert at the same pool-vs-oracle spread. The difference is that
the floor version borrows the larger buffer and then defends it, so it carries slightly more USDT
debt for the same result — 0.05% more at our numbers. We kept the floor because it is already
deployed and states the intent where a reader will look for it, but shrinking the buffer would be
the marginally better shape, and if you would rather we do that we will.

Also from that review, and fixed rather than argued: the floor shipped with no test touching it.
`test/LeverVaultBuildFloor.t.sol` now pins both bounds — proven red at 30 and 35 bps, where the
budget reaches the buffer and the floor silently stops binding, and at 15 bps, where it drops under
measured slippage and would revert legitimate builds.

### Finding 5: Settlement cadence is not "every five minutes" when the vault is idle
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The README states the vault "settles every five minutes" and the on-chain `vaultDataSchema()` description promises "Gains are settled automatically every 5 minutes." The implementation, however, only reschedules the next wake at `TRIGGER_INTERVAL` (5 minutes) when the previous wake found work to do. When `_pickAction()` returns 0 (nothing to do), `trigger()` reschedules at `IDLE_INTERVAL = 1 hours` instead. Consequently, after an idle wake, any gain, deploy, or rebalance need that arises is not checked again for up to an hour, not five minutes.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:trigger`
  - `src/flap/LeverVault.sol:_schedule`
  - `src/flap/LeverVault.sol IDLE_INTERVAL constant`
  - `src/flap/LeverVaultFactory.sol:vaultDataSchema`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct as written, and the string was the thing that was wrong, not the schedule. The hourly back-off is deliberate — a wake costs a trigger fee, and paying it every five minutes to be told there is nothing to do drains the same balance your own Finding 6 in the previous report identified as having no funding source. But the schema said "every 5 minutes" without qualification, and a UI reading that would have shown users something the contract does not do.

Fixed by making the string say what the code does, on chain and in the README: checked every five minutes while there is work, hourly once idle. Both halves of the bilingual string were updated together. Note the cadence is a floor on responsiveness, not a cap: the three working functions are permissionless and paid, so anyone may call `deployPending`, `harvest` or `rebalance` at any moment without waiting for a wake, and `rebalance` pays 0.3% whenever leverage is outside the band. Read the new text at `0x62D1C54CeA0a03096741dc72e51E7a4c5Ec0ACFA`. / 属实，且错的是文案不是调度。空闲时退避到一小时是有意为之——每五分钟醒来一次只为得知无事可做，会消耗上一版 Finding 6 指出的那笔没有资金来源的费用。已改为如实表述，中英两半同时更新。另注：这只是响应下限不是上限，三个工作函数无需等待唤醒、任何人可随时调用。


### Finding 6: Holders receive less than the documented 70% of realised gain on manually-called harvests
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The README states harvest "pays 70% of the realised gain to holders as WBNB dividends and 30% to the project." In `_harvest`, the caller bounty (`HARVEST_BOUNTY_BPS = 50`, i.e. 0.5%) is deducted from the freed amount first (`net = freed - bounty`), and only then is the 70/30 split applied to `net`. On a manually-called harvest the holders therefore receive 70% of `freed * 99.5%` (~69.65% of the realised gain), not 70% of the realised gain. (On the automatic path `bountyTo == address(0)` so bounty is 0 and holders get exactly 70%.)
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_harvest`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Correct, including the parenthetical — on the automatic path the bounty is zero and holders receive exactly 70%. We considered changing the code so holders always get a full 70% by taking the bounty out of the project's 30%, and decided against it: the bounty is what makes a keeperless design work, it is paid to whoever does the work rather than to us, and charging it entirely to the project would make the project's share depend on how often a stranger beats the automatic path to the call. Holders and project sharing it in the same 70/30 proportion is the neutral split.

So the string was fixed rather than the arithmetic. The harvest method description now says the caller takes 0.5% first and the remainder splits 70/30, and states that the automatic path pays no bounty so holders receive the full 70% there. The factory's `vaultDataSchema` carries the same correction, both language halves. Read them at `0x4F6f3D2E103A90599B994623B058BF8C984Adc4B` and `0x62D1C54CeA0a03096741dc72e51E7a4c5Ec0ACFA`. / 属实，包括括号里那句。我们考虑过改代码让持有者始终拿满 70%（赏金从项目方 30% 里出），最终没改：赏金付给干活的人而非我们，全由项目方承担会让项目方份额取决于陌生人抢没抢在自动路径前面。改的是文案：说明调用者先拿 0.5%，余额再按 70/30 分，自动路径不付赏金。

---

Findings 1-3 were fixed and deployed before this report was generated; findings 4-6 are fixed
in the deployment below. Register `0x62D1C54CeA0a03096741dc72e51E7a4c5Ec0ACFA`; the vault implementation carrying these fixes is
`0x4F6f3D2E103A90599B994623B058BF8C984Adc4B`.
Reproduce with `bash scripts/test.sh` and `./submission/check`.
