# Flap Vault Interaction Risk Report

Generated: 2026-09-04 05:08:28 UTC

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
### Finding 1: Untracked idle BNB inflates measured gain, causing `harvest` to shrink the position by more than the realized gain (principal leakage)
- **Severity:** Low
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** `_gain(p) = nav(p) - (costBasis + pendingRevenue)`, where `nav` counts the full native balance as idle. The basis only tracks idle BNB that is recorded in `pendingRevenue`. Several paths leave idle native/WBNB in the vault that is NOT reflected in `pendingRevenue`: the flash-callback surplus (`if (got > owed) IWNative(WBNB).withdraw(got - owed)`), the floor-to-zero fee handling in `_schedule`, and WBNB dust left by `_repayOnce` during automatic deleverage (`_deleverBy`, unlike `_shrinkBy`, never unwraps its leftover WBNB). Any such untracked idle amount D is counted as profit by `_gain`. In `harvest`, `_shrinkBy(gain, p)` sizes its proportional shrink against the position-only NAV, so an inflated `gain` removes `trueGain + D` of value from the Venus position while `costBasis` is deliberately left unchanged. Thus a small amount of position principal is redeemed and distributed to holders/project/caller as if it were gain.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_gain`
  - `src/flap/LeverVault.sol:_harvest`
  - `src/flap/LeverVault.sol:_deleverBy`
  - `src/flap/LeverVault.sol:_repayOnce`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Real, though the mechanism is not quite as described, worked through precisely rather than assumed: `_shrinkBy(gain, p)` targets `navBnb = _nav(p) - address(this).balance` (position-only equity) as its base, so it always frees *exactly* `gain` from the position, by construction — an inflated `gain` does not make harvest free *more* than `gain` says, and the remaining position value always lands exactly at whatever `costBasis` claims. The real, distinct consequence is the one the fix addresses: capital left as untracked idle balance is never picked up by anything again (`_deploy` reads `pendingRevenue`, not raw balance), so it sits stranded, and if `costBasis` is not adjusted to match, every later `_gain` read is suppressed by that same amount until the position climbs back over it — the same shape already fixed for `_rebalance` two rounds ago, here at two more sites `_rebalance` doesn't reach: **`_deploy`'s own flash-repay swap can realise a small windfall the identical way `_rebalance`'s already does** — fixed by capturing it into `pendingRevenue`, basis-neutral. **`_deleverBy` lacked the WBNB-dust sweep `_shrinkBy` already has at its tail** — `_nav`'s `idle = address(this).balance` is native only and cannot see an ERC20 WBNB balance at all, so this dust was not "counted as profit" as described, it was simply invisible and permanently stranded; both functions now call one shared sweep. The `_schedule` floor-to-zero case was checked and moves `_gain` in the opposite direction from what's described — it can only understate gain, never inflate it, since `pendingRevenue` cannot fall below zero while the real fee draw is uncapped; no fix needed there. Covered by `test/LeverVaultUntrackedSurplus.t.sol`; both fixes proven red by reverting them in isolation. / 确认，但机制并非"harvest 多赎回本金"——`_shrinkBy` 按设计精确释放 `gain`。真正的后果是未追踪的闲置余额永远不会被再次拾取，`costBasis` 若不同步调整会永久压低此后所有 `_gain` 读数,和两轮前修复 `_rebalance` 是同一形状;这次在 `_deploy` 自身与 `_deleverBy` 各修了一处。

### Finding 2: Lever-up rebalance pays a negligible bounty, contradicting the documented "paid, permissionless" incentive
- **Severity:** Low
- **Confidence:** Medium
- **Detected by:** doc_review
- **Description:** The README states the three working functions "are permissionless and each pays a fixed bounty to whoever calls it," and lists `rebalance` among them. The UI schema also advertises rebalance as "Anyone may call; pays 0.3% of what it frees." In `_rebalance`, the deleverage branch synthesises a bounty by shrinking the position by `owedBounty = excess * REBALANCE_BOUNTY_BPS / BPS`, so a deleverage caller is paid ~0.3% of the rebalanced size. But the lever-up branch simply calls `_build(0, p)` and then computes `bounty = freed * REBALANCE_BOUNTY_BPS / BPS`, where `freed = address(this).balance - bnbBefore`. A lever-up build routes the flashed WBNB straight into vBNB collateral and only leaves the small flash surplus (`got - owed`) as native balance, so `freed` is a tiny residual and the resulting bounty is effectively ~0.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:_rebalance (else branch: _build(0, p) and bounty = freed * REBALANCE_BOUNTY_BPS / BPS)`
  - `src/flap/LeverVault.sol:vaultUISchema (m[5] rebalance description)`

> **Status:** `[ ]` TP、`[ ]` FP、`[ ]` By Design、`[x]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):** Already resolved, in a prior round of this same review. The code quoted here — `bounty = freed * REBALANCE_BOUNTY_BPS / BPS` on the lever-up branch — is the version that predates our sixth-round response: that rate-based computation was replaced with a hardcoded zero once we found it could pay an incidental amount from the same flash-buffer leftover, and both the on-chain schema and the README were reworded to state plainly that levering up pays no bounty at all, rather than "effectively ~0". Read back from the currently deployed implementation, `vaultUISchema()`'s `m[5].description` now reads "levering up pays no bounty", not the "pays 0.3% of what it frees" text this finding quotes. No further change needed; marking Acknowledged rather than FP because the underlying gap this finding is pointing at was real at the commit this analysis ran against. / 该分支的赏金计算在上一轮就已被改为硬编码 0，链上 schema 与 README 也已同步改为准确表述;这里引用的仍是上一轮之前的旧文案。

---

## Fixes deployed / 修复部署

Finding 1's two fixes are on chain, on BNB Chain (56) and BSC testnet (97) at identical
addresses. Finding 2 needed no new change; see its Reason above.

| Contract | Address | Runtime |
|---|---|---:|
| `LeverVaultFactory` (proxy — register this) | 0x3f09f61D8460D330b7387e460FCcc3A90cCe4313 | 279 |
| `LeverFactoryBeacon` | 0xC585Ab122A5Da00D02bf87a2FDbbA34c8305A155 | 785 |
| `LeverVaultFactory` (implementation) | 0x69bd2D1f586A0A8974D33695DEe4Ab87cB0f36dE | 7,745 |
| `LeverBeacon` | 0xF37B56A19B7C419EC534f825D6119B932209B227 | 785 |
| `LeverVault` (implementation) | 0xf750Cead8810D524d7454b6c1d246D677950bdfd | 23,193 |

| Chain | Block | Transaction |
|---|---:|---|
| BNB Chain, 56 | 119,921,946 | 0x4703e5f57a4cdd7cc8eb8528adc0e3eea4dc658cf84e91c1b427631339e02a23 |
| BSC testnet, 97 | 129,066,437 | 0xacbca55a95260c6ff4a9516ba29cc76640c09deb59e4e3fcc7606a308abbf221 |

The vault implementation's runtime is byte-identical to the local build. Every address this
replaces is listed under `retired` in `deployments/56.json` and must never be registered.

## Verification / 复现

```bash
bash scripts/test.sh     # 59 forge tests + 33 live-state assertions + 8 vault-UI checks
./submission/check       # deployed bytecode vs local build, both beacons' owners, wiring
```

Green as of this response.
