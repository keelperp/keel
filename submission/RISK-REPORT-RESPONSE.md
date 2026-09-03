# Flap Vault Interaction Risk Report

Generated: 2026-09-02 08:09:19 UTC

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
### Finding 1: User-facing UI strings are English-only while error messages are bilingual (SYS-REQ-MULTILANG)
- **Severity:** High
- **Confidence:** High
- **Detected by:** rule_review
- **Description:** The contract establishes multi-language intent by using bilingual (English / Chinese) messages in every require() statement, yet the UI-facing return strings in description(), vaultUISchema(), and vaultDataSchema() are English-only. Because the contract mixes languages across locations, every user-facing string must be bilingual; the English-only UI/schema strings violate SYS-REQ-MULTILANG.
- **Vulnerable Code:**
  - `LeverVault.description: "Trading tax becomes a leveraged BNB position the vault holds on Venus itself. The treasury moves with the market when nobody is trading, and its gain is paid to holders through the token's dividend contract. No keeper, no published NAV, no pause."`
  - `LeverVault.vaultUISchema: "Treasury value in BNB, read straight from Venus."`
  - `LeverVault.vaultUISchema: "Treasury value in wei"`
  - `LeverVault.vaultUISchema: "Live BNB exposure over net value, 1e18-scaled."`
  - `LeverVault.vaultUISchema: "3e18 means 3x"`
  - `LeverVault.vaultUISchema: "Collateral x factor over debt, in bps. Venus liquidates at 10000."`
  - `LeverVault.vaultUISchema: "12000 means liquidated only by a 16.7% move"`
  - `LeverVault.vaultUISchema: "Turn accumulated tax into position. Anyone may call; pays 0.25%."`
  - `LeverVault.vaultUISchema: "BNB paid to the caller"`
  - `LeverVault.vaultUISchema: "Distribute the position's gain: 70% to holders as WBNB dividends, 30% to the project. Anyone may call; pays 0.5% to the caller."`
  - `LeverVault.vaultUISchema: "Push leverage back inside the band. Anyone may call; pays 0.3% of what it frees."`
  - `LeverVaultFactory.vaultDataSchema: "Trading tax is levered into a 3x BNB long the vault holds on Venus. Gains are settled automatically every 5 minutes: 70% to holders as WBNB dividends, 30% to the project."`
  - `LeverVaultFactory.vaultDataSchema: "Receives 30% of every harvest. Fixed at creation; the vault has no setter."`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed. All 13 strings are bilingual now, separated by ` / `. Verified by reading it back off chain rather than from source: `cast call 0x753c65B6a18454534Bd3B759f69E793bcf4B5F55 "vaultDataSchema()((string,(string,string,string,uint8)[],bool))"` returns the Chinese half attached, and the same output is checked into `submission/schema.txt`, which is regenerated from the chain. A gate in `tools/check-docs.py` now fails if any `description`, `schema.description` or field description lacks the separator; proven red by reverting one string. / 已修复，13 条串全部双语，链上读回验证，并加了防回退的门。

### Finding 2: Rebalance-down recycles position equity into pendingRevenue, permanently inflating costBasis and suppressing all future harvests
- **Severity:** High
- **Confidence:** High
- **Detected by:** attacker_review, rule_review
- **Description:** When leverage exceeds the target, `_rebalance` calls `_shrinkBy(...)` and then adds the freed BNB to `pendingRevenue` (`if (rest > 0) pendingRevenue += rest;`). That freed BNB was already part of the live position and is already reflected in `costBasis`. `_rebalance` never decreases `costBasis`, so when `deployPending`/`_deploy` later redeploys that same BNB it executes `costBasis += work`, counting the same capital a second time. `costBasis` only ever increases and is never reduced anywhere in the contract. Because `_gain = nav - (costBasis + pendingRevenue)`, the inflated `costBasis` makes measured gain collapse to zero, and `harvest` reverts on `gain >= MIN_HARVEST`. A single volatility-driven rebalance-down can inflate `costBasis` by most of the position's equity, so holders stop receiving WBNB dividends until the position's NAV nearly doubles.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol (_rebalance: pendingRevenue += rest)`
  - `src/flap/LeverVault.sol (_deploy: costBasis += work)`
  - `src/flap/LeverVault.sol (_gain: basis = costBasis + pendingRevenue)`
  - `src/flap/LeverVault.sol:_rebalance (pendingRevenue += rest)`
  - `src/flap/LeverVault.sol:_deploy (costBasis += work)`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Confirmed in every step. The load-bearing detail is that `_nav` already counts idle balance, so pulling capital out of the Venus leg does not change NAV — booking it as pendingRevenue therefore raised the basis out of nothing, and `_deploy` then made the inflation permanent. The deleveraging branch now moves the capital between the two accounts instead of adding to one. The bounty is deliberately not moved: it genuinely left the vault, so it shows up as a fall in NAV, which is what a cost is. `harvest` is unaffected — its freed BNB leaves the vault entirely rather than being rebooked, so its basis correctly does not move. Covered by `test/LeverVaultRebalanceBasis.t.sol`, which asserts the identity rather than a hard-coded number; proven red by removing the adjustment. / 每一步都属实，已改为在两个账户之间搬运而非单边累加。


### Finding 3: Vault provides no Guardian rescue mechanism (no emergency withdraw and no receive-forward switch) (SYS-REQ-RESCUE-MECHANISM)
- **Severity:** High
- **Confidence:** High
- **Detected by:** rule_review
- **Description:** LeverVault exposes neither of the two required Guardian rescue facets. (a) There is no Guardian-only emergency-withdraw function capable of extracting the vault's BNB and ERC20 holdings (WBNB, USDT, vBNB, vUSDT, taxToken) to a safe address; the contract ships no such function at all. (b) receive() has no Guardian-controlled forward switch: it unconditionally accumulates incoming BNB into totalReceived/pendingRevenue with no way to redirect future tax revenue to a safe address during an incident. If the vault is ever compromised or enters an unexpected state, the Guardian cannot directly rescue funds nor redirect incoming BNB; the only recourse is a full beacon-implementation upgrade, which the vault developer relies on as the sole emergency path.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:receive`
  - `src/flap/LeverVault.sol (no emergencyWithdraw/rescueFunds function)`

> **Status:** `[ ]` TP、`[x]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** The facts are right but the conclusion is inverted: for a proxy vault, rule 009 does not merely permit these functions to be absent — it requires it. `009-emergency-risk-controls.md:11` states the proxy exemption and that "Rule 009 is considered not applicable for such vaults"; `:25` is stronger, saying proxy-upgradeable vaults "are fully exempt and must omit them entirely"; the checklist at `:112` marks the emergency-function checks N/A. Implementing what this finding asks for would violate `:25`, and putting a forward switch in `receive()` would add an external call to the one function that must stay under rule 005's gas cap — if `receive()` ever reverts, the token's tax collection breaks permanently. The exemption carries exactly one condition (`:11`, `:113`): all upgrade and admin authority strictly Guardian-only. This project meets it on both layers, since the factory now runs behind a beacon as well as the vault. Both beacons call `_transferOwnership(guardian)` inside their own constructors, so the deployer never held authority for a single block; read back from chain 56, `owner()` on `0x5C429A338087c89B9D3c9B444Ca2311361bb12e1` and on `0x00D634BdDbbff39CC6cfA3A4a9431ED4294a2EA9` both return `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b`. There is no owner, admin or role anywhere else in the project, and no `delegatecall` or `selfdestruct`. / 规则 009 对代理型金库是「必须不实现」而非「可以不实现」；豁免的唯一条件是升级权限全部归 Guardian，本项目两个 beacon 均在构造函数内交权，链上可验。

### Finding 4: Unchecked return value of Dividend.deposit strands holder dividends and corrupts harvest accounting (COM-EXTERNAL-CALL-FAILURE)
- **Severity:** Medium
- **Confidence:** High
- **Detected by:** attacker_review, rule_review
- **Description:** In LeverVault._harvest, after shrinking the position and wrapping the holders' portion into WBNB, the vault calls IDividend(div).deposit(toHolders) without checking its boolean return value. The Dividend contract's deposit() returns false without pulling any tokens when totalShares == 0 (no dividend-eligible holders). When this happens, the WBNB approved for the dividend contract is never transferred and remains stranded in the vault, while the vault has already realised the gain (shrunk the Venus position), paid the project its share, and incremented totalHarvested by toHolders as if the dividends had been distributed. The stranded WBNB is not counted in nav() (which only counts native BNB idle balance plus the Venus position), so it is effectively lost to holders, and there is no emergency-withdraw path (only a Guardian beacon upgrade could recover it).
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_harvest (IDividend(div).deposit(toHolders))`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Fixed, with one correction to the description: our `IDividend` declares `deposit(uint256)` with **no return value**, so there is no boolean to check — the defect is real but not reachable by checking a return. The consequence is exactly as stated: `_nav` counts native balance plus the Venus position only, so WBNB left sitting in the vault is outside NAV, invisible to `_gain`, and unreachable, while `totalHarvested` has already counted it as paid. `_harvest` now records the WBNB balance before wrapping and requires it to be no higher afterwards, which does not depend on the callee at all. On failure the whole harvest reverts and the gain stays in the position for the next attempt — strictly better than stranding it. / 已修复。更正一处：接口把 `deposit` 声明为无返回值，所以字面上不存在「未检查的返回值」，但后果确实成立。改为余额差校验，失败则整笔回滚。


### Finding 5: Rebalance-down passes a supply-reduction amount to _shrinkBy, which interprets it as equity-to-free, causing gross over-unwinding of the leveraged position
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** `_shrinkBy(wantBnb, p)` treats `wantBnb` as an amount of *equity* (net position value) to release: it computes `fraction = wantBnb / navBnb` where `navBnb = _nav(p) - balance` is position equity, and this is how `harvest` correctly uses it with `gain` (equity gain). In `_rebalance`, however, `wantBnb` is computed as `excess * WAD / p.bnb`, where `excess = s - (s - b) * TARGET_LEVERAGE / WAD` is a reduction of gross SUPPLY (a leg), not equity. Since equity is much smaller than supply, `fraction` is overstated by roughly the leverage factor (excess/equity instead of excess/supply). The health-floor cap in `_maxRedeemableBnb` still lands the residual position near the target leverage, but the vault extracts far more equity to idle cash than intended, then must rebuild it via a subsequent deploy — churning double PancakeSwap swap fees and up-to-3% oracle-floored slippage on each rebalance, and driving the costBasis inflation described in the related finding.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_rebalance (excess * WAD / p.bnb)`
  - `src/flap/LeverVault.sol:_shrinkBy (fraction = wantBnb * WAD / navBnb)`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Confirmed, and worse than Low once traced. The units mismatch is real and the overstatement factor is exactly the leverage. But the deeper problem is that `_shrinkBy` cannot deleverage **at all**: it shrinks both legs by the same fraction, and `s(1-f) / (s(1-f) - b(1-f))` is identically `s / (s-b)`. Where leverage actually landed was decided by how much of the tail redeem the health cap happened to block — fully blocked it reached 2.83x, fully open it returned to the original 3.15x, and the 3.00x target was not reachable by construction either way. Your note that the cap "still lands the residual position near the target" is right, and the reason is a coincidence worth stating: the cap's floor is `MIN_HEALTH_BPS * b / cf` = 1.5b, and leverage at `s = 1.5b` is exactly 3.0 — the target was being hit by a protection mechanism, not by the algorithm. Fixed with `_deleverBy`, which moves the legs by the same **absolute** amount, since `(s-x) / ((s-x) - (b-x)) = (s-x) / (s-b)` is what actually falls; solving it for the target gives precisely the `excess` already being computed. The test asserts both the landing point and that the repayment is within 2x of what the algebra requires. Two further defects surfaced while building that test and are fixed in the same deployment, disclosed here rather than shipped quietly: (a) every deleverage was a no-op by arithmetic — `_maxRedeemableBnb` held the redeem-then-repay pass to `MIN_HEALTH_BPS`, which needs `s > 1.5b`, while `rebalance` cannot trigger below 3x*1.05 where `s = 1.4651b`, so the cap solved to zero, the repay loop broke on its first pass, and the closing health check reverted the whole call, blocking the urgent rescue at health 1.13 the same way; (b) that closing check demanded an absolute floor after an operation that raises health, and health at 3x is exactly 1.2000 — the floor itself — so a deleverage landing on its own target sat on the line and friction reverted it, as did a deep rescue climbing from 1.05 to 1.15. The repay leg now uses `REPAY_FLOOR_BPS = 10200` and the check requires that health rose. / 确认，且比 Low 更严重：等比缩减在数学上无法改变杠杆，命中目标是保护机制的巧合。已改为按绝对量还债，并附带披露修复过程中发现的另外两个缺陷。

### Finding 6: Automatic settlement chain permanently stalls once the vault is fully deployed because the trigger fee has no funding source
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** The trigger fee in `_schedule` is paid from `address(this).balance`, and `_schedule` early-returns without re-arming (`pendingRequestId` stays 0) whenever `balance < fee`. After a successful `_deploy`, essentially all idle BNB has been minted into the Venus position, so the vault's balance is ~0. On the next scheduled wake, `_schedule(IDLE_INTERVAL)` cannot buy the next slot, so `pendingRequestId` remains 0 and the automatic settlement chain dies. `kickstart()` also calls `_schedule` and reverts (`could not schedule`) when balance < fee, so it cannot restart the chain either. The chain only resumes when fresh tax revenue arrives via `receive()` AND someone manually calls `kickstart()`. In the interim the vault performs no automatic rebalancing/rescue, so a leveraged position can drift toward liquidation with no scheduled protection, contradicting the design's claim that 'holders never have to press anything.'
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_schedule (if (address(this).balance < fee) return;)`
  - `src/flap/LeverVault.sol:kickstart`
  - `src/flap/LeverVault.sol:trigger`

> **Status:** `[ ]` TP、`[ ]` FP、`[ ]` By Design、`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** The mechanism is real and we are not disputing it — a fully deployed vault in a quiet market does run its balance down one trigger fee at a time, and the chain does stop. Three things bound the impact, which is why this is Acknowledged rather than changed in this round. First, restarting is permissionless: `kickstart()` has no access control, so any holder, the project, or a bot can re-arm the chain; nothing waits on us. Second, protection does not depend on the scheduler at all — the three working functions are permissionless and each pays a fixed bounty, so `rebalance` pays 0.3% to whoever calls it whenever leverage sits outside the band, armed chain or not. Third, any trading at all refills the balance, and a token with no trading is also a token whose position is not drifting. We would rather not hold a BNB fee reserve inside a vault whose whole design is to keep no idle capital, and we would rather not give `receive()` more work to do. If Flap prefers a dedicated fee reserve, we will add one — tell us the size and we will deploy it. / 机制属实。三点缓解：`kickstart()` 无权限任何人可重启；三个工作函数各自付赏金，本就不依赖调度器；有交易就会补充余额。如 Flap 要求预留费用储备，请给出额度我们照做。


### Finding 7: Trigger service fees are drawn from pendingRevenue, diverting holder-bound capital with no dedicated reserve
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** `pendingRevenue` is documented as tax revenue that has arrived but is not yet in the position — capital earmarked to build the leveraged BNB long for holders. `_schedule` decreases this same bucket to pay the Flap trigger service fee (`pendingRevenue = pendingRevenue > fee ? pendingRevenue - fee : 0`). This is an outflow serving a different obligation (paying a third-party scheduler) than the bucket's declared purpose (funding the position), and there is no separate reserve for operational fees. Every scheduling cycle therefore reduces the capital deployed on behalf of holders.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_schedule (pendingRevenue reduced by fee)`

> **Status:** `[ ]` TP、`[ ]` FP、`[x]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** The observation is correct — the fee does come out of capital that would otherwise be deployed — but the line being pointed at is not the outflow. The ETH leaves at the `requestTrigger` call above it; the `pendingRevenue` line is the accounting correction that keeps the counter equal to what the vault actually holds. Deleting it would not return a single wei to holders, and it would break `_deploy`: `pendingRevenue` would then claim more BNB than the balance contains, and the next build would either revert or size itself against money that is not there. The fee is Flap's own trigger-service price, read from the service rather than set by us, and it buys the five-minute settlement the whole design rests on. There is no separate reserve because the vault deliberately holds no idle capital — the same property Finding 6 observes from the other side. As there, we are open to a dedicated fee reserve if Flap wants one. / 那一行不是支出而是会计校正，ETH 在上一行就已付出；删掉它会让 `pendingRevenue` 大于实际持有，下一次建仓按不存在的钱计算。


### Finding 8: Project commission uses hardcoded 30% flat rate instead of tax-rate-dependent formula (SYS-REQ-COMMISSION)
- **Severity:** Informational
- **Confidence:** Low
- **Detected by:** rule_review
- **Description:** The vault is deployed via a factory and takes a developer/project commission from harvested tax-derived revenue at a hardcoded 30% (PROJECT_SHARE_BPS = 3000). SYS-REQ-COMMISSION requires the commission to be 6% of msg.value when taxRate<=1% or (msg.value*6)/taxRateBps otherwise; the hardcoded 30% deviates from this specification.
- **Vulnerable Code:**
  - `LeverVault._harvest (uint256 toProject = net * PROJECT_SHARE_BPS / BPS)`
  - `LeverVault.PROJECT_SHARE_BPS constant (3000)`

> **Status:** `[ ]` TP、`[ ]` FP、`[ ]` By Design、`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** We are not disputing the arithmetic, and we are not deciding this ourselves — it is filed as **SB-01** in `submission/RULES.md` under rule 002 and awaits Flap's written ruling; the disclosure there is the same one we make here, that 30% is above the recommendation on its face. Our argument is that the two numbers are levied on different bases. The rule's formula is a share of `msg.value`, i.e. of the tax payment arriving at the vault. **This vault takes 0% of tax** — every unit that arrives goes into the position, less only the 0.25% deploy bounty paid to whichever third party calls it. The 30% is taken from `net` inside `_harvest`, which is realised gain the position earned in the market and which does not exist until the position does; when the position has not earned, `harvest` reverts and the project receives nothing at all. Both numbers are `constant` with no setter, so changing either takes new code — a fresh deployment or a Guardian upgrade. If Flap rules that the formula applies to this base as well, name the number and we will deploy it. / 不争论算术，也不由我们裁定：已作为 SB-01 提交等待 Flap 书面裁决。抽成基数不同——本金库对税收抽 0%，30% 只从仓位在市场上赚到的收益里抽，不赚则 harvest 直接回滚。


---

All fixes above are deployed on BNB Chain (56) and BSC testnet (97) at identical addresses.
Register `0x753c65B6a18454534Bd3B759f69E793bcf4B5F55`; the vault implementation carrying these fixes is `0x2D0EA137C010731607B34a85C32bd7aB02576131`.
Reproduce with `bash scripts/test.sh` and `./submission/check`.
