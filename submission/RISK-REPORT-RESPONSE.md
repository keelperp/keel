# Flap Vault Interaction Risk Report

Generated: 2026-09-05 05:51:30 UTC

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
### Finding 1: Reentrancy guard is not active on the automatic settlement path, and _harvest calls the arbitrary project address before finalizing state (COM-REENTRANCY)
- **Severity:** High
- **Confidence:** Low
- **Detected by:** attacker_review
- **Description:** The vault protects its three work functions (deployPending/harvest/rebalance) with the nonReentrant modifier, but the automatic settlement path — trigger() — this.settleSelf() — _deploy/_harvest/_rebalance — never sets the _entered guard (neither trigger nor settleSelf is nonReentrant). Inside _harvest, the vault makes a low-level call to the creator-controlled `project` address (`project.call{value: toProject}("")`) BEFORE finalizing the harvest (totalHarvested has been incremented, but the WBNB wrap, dividend deposit, final health check, and bounty are all still pending). Because the guard is inactive on this path, a malicious `project` contract can reenter deployPending()/rebalance()/harvest() during the automatic harvest. The most direct consequence is griefing: by reentering deployPending() the project consumes idle balance (minting it into Venus), so the subsequent `IWNative(WBNB).deposit{value: toHolders}()` reverts, rolling back the automatic harvest. Repeated on every scheduled harvest this permanently blocks the automatic (zero-bounty) dividend path, forcing holders to depend on manual harvest() calls that cost them a 0.5% bounty.
- **Vulnerable Code:**
  - `src/flap/LeverVault.sol:trigger`
  - `src/flap/LeverVault.sol:settleSelf`
  - `src/flap/LeverVault.sol:_harvest (project.call before dividend deposit / health check)`

> **Status:** `[x]` TP、`[ ]` FP、`[ ]` By Design、`[ ]` Acknowledged
> **Reason (if FP / By Design / Acknowledged):**
Confirmed exactly as described, line for line. `_entered` (`src/flap/LeverVault.sol:184`) is
touched nowhere except the `nonReentrant` modifier itself, and that modifier sits only on
`deployPending()`, `harvest()`, `rebalance()` and `kickstart()` -- never on `trigger()` or
`settleSelf()`. `settleSelf` runs `_deploy`/`_harvest`/`_rebalance` as plain internal calls, so
the entire automatic action executes with `_entered == false` throughout. Inside `_harvest`, the
call to `project` happens before `totalHarvested` is used downstream, before the WBNB wrap and
dividend deposit, before the health-floor check, and before the bounty payout -- exactly the
ordering the report cites. A reentrant call from `project`'s fallback into `deployPending()` at
that point passes the `nonReentrant` check, because `_entered` is still false: nothing else in
the contract (the only other guard, `_flashArmed`, is unrelated and untouched during a harvest)
stands in its way.

We also checked how far this actually reaches, since the report itself rates confidence Low.
`_gain()` is computed from live Venus legs against `costBasis`, and `_shrinkBy` -- called before
the `project.call` -- has already driven the position down by the harvested amount by the time
the reentrant call lands, so a reentrant `harvest()` recomputes `_gain()` against an
already-shrunk position and fails its own `MIN_HARVEST` check: double-harvesting the same gain is
not reachable through this hole. `_deploy` and `_rebalance`, reentered directly, only ever pay
the same bounty an ordinary permissionless caller would already be entitled to at that moment --
and on the automatic path itself (`bountyTo == address(0)`), both functions force their own
bounty to zero and never make an external call at all, so this window is real at exactly one call
site: `_harvest`'s payout to `project`. The impact we can substantiate is denial-of-service on
the automatic, zero-bounty settlement (as described, plus a coincidental angle the report did not
name: a hostile `project` could use the same reentrancy to front-run every other caller for the
`deployPending()` bounty on every scheduled harvest, ahead of any competing bot) -- not a fund-loss
or double-spend path.

Fixed at the root rather than at the one call site the report named: `settleSelf(uint8 action)`
now carries `nonReentrant` itself.

```solidity
function settleSelf(uint8 action) external nonReentrant {
    require(msg.sender == address(this), "LeverVault: self only / 仅限自调用");
    ...
}
```

`settleSelf` is the sole gateway all three automatic actions run through and has exactly one
caller (`trigger()`'s own `this.settleSelf(action)`, wrapped in a try/catch that already turns
any revert into `WorkFailed` and retries five minutes later), so guarding it there closes the
window for `_deploy`, `_harvest` and `_rebalance` at once, present and future, rather than only
patching the `project.call` this report happened to find. It costs 66 bytes of runtime and no
behavioural change on the honest path: an ordinary, non-reentrant `project` is paid exactly as
before.

Covered by `test/LeverVaultAutomaticHarvestReentrancy.t.sol`. `ReentrantProject`'s `receive()`
walks straight back into `deployPending()` when armed; the test drives an automatic harvest via
`vm.prank(address(v)); v.settleSelf(3)` (reproducing exactly what `trigger()`'s internal call
does) with enough `pendingRevenue` sitting idle that the reentrant deploy would have fully
succeeded had the guard not caught it. It asserts the reentrant call reverted and that
`totalDeployed`/`pendingRevenue` never moved during the harvest -- proven red by reverting
`settleSelf` to its unguarded form, where the same reentrant call goes through and `totalDeployed`
visibly increases mid-harvest. A second test confirms an ordinary, honest `project` is still paid
in full on the automatic path with the guard active, so the fix costs the normal case nothing.

完全按描述核实无误：`_entered` 只在 `nonReentrant` 修饰符里被读写，而这个修饰符只挂在
`deployPending`/`harvest`/`rebalance`/`kickstart` 上，`trigger`/`settleSelf` 从未使用它，所以整个自动
结算过程中 `_entered` 全程为假。`_harvest` 对 `project` 的外部调用确实发生在分红存入、健康度检查、赏金
发放之前，此时重入 `deployPending()` 能直接通过重入锁检查。深入追查后确认：由于 `_shrinkBy` 在外部调用
之前已经把仓位收益抽走，重入 `harvest()` 无法二次分账；`_deploy`/`_rebalance` 在自动路径上赏金恒为零且
不发起外部调用；所以影响范围止步于自动结算的拒绝服务（外加报告未提到的一点：恶意 project 可以借重入抢先
拿到本该属于其他调用者的建仓赏金），没有资金被多算或偷走的路径。修复方式是给 `settleSelf` 本身加上
`nonReentrant`，一次性覆盖它调用的三个动作，而不是只补报告点名的那一处调用，诚实的 `project` 不受任何
影响。

---

## Fixes deployed / 修复部署

On chain, on BNB Chain (56) and BSC testnet (97) at identical addresses.

| Contract | Address | Runtime |
|---|---|---:|
| `LeverVaultFactory` (proxy — register this) | 0xf68e42BB99baBD2D0e2c365B438c81E4269AaC7f | 279 |
| `LeverFactoryBeacon` | 0xFe6747aD23A0d24998A6DF969d966AE488028DD2 | 785 |
| `LeverVaultFactory` (implementation) | 0x9319f9fFC7227aA7BC4c68297c1ffF0557144124 | 7,745 |
| `LeverBeacon` | 0x38424E67241c8f8C0A2575c8EBBb1DA2778843bB | 785 |
| `LeverVault` (implementation) | 0x31b4037e35D356B5E09696f06b59169aB11A650F | 23,221 |

| Chain | Block | Transaction |
|---|---:|---|
| BNB Chain, 56 | 120,062,943 | 0xe5b9d7d80fb0066d681fd64e8639fd084644797ae0c6bdfd3af421407d8144d0 |
| BSC testnet, 97 | 129,207,476 | 0x714b072360bf76277cc232a85f9d40ef0ae8d658d8d2eb2d089f94f0fadd632f |

The vault implementation's runtime grew by 66 bytes (23,155 to 23,221, margin 1,355) for the one
new modifier on `settleSelf`; every other contract in the set is byte-identical to the previous
round, redeployed only because both beacons require a fresh implementation address to point at.
Every address this replaces is listed under `retired` in `deployments/56.json` and must never be
registered.

## Verification / 复现

```bash
bash scripts/test.sh     # 65 forge tests + 33 live-state assertions + 8 vault-UI checks
./submission/check       # deployed bytecode vs local build, both beacons' owners, wiring
```

Green as of this response.
