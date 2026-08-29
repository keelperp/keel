# LeverVault — 提交给 Flap 的说明

**版本**:factory spec `v2.2` · solc 0.8.26 / Cancun / optimizer 200 / 无 viaIR
**状态**:代码冻结候选,`NOT_DEPLOYED`
**自审**:见 `AUDIT.md`(十条规则逐条)。**无第三方审计。**

---

## 这个金库做什么

代币的买卖税以原生 BNB 进入金库,金库把它建成一个 **3 倍 BNB 多头**,持仓在合约自己名下
(Venus 借贷,合约是借款人也是抵押人)。**Flap 的定时服务每 5 分钟唤醒一次**,金库按优先级
做一件事:救仓位 → 建仓 → 分配收益 → 再平衡。仓位赚到钱时,收益的 **60% 通过代币自己的
分红合约以 WBNB 发给持有者,40% 给项目方**。

没有 keeper 账户,没有对外公布的净值,没有暂停开关。`nav()` 是一个 view。

---

## SB-01:项目方 40% 分成,请求 Flap 书面裁定

### 这是两层不同的钱

Flap 的 factory commission 抽的是**税**——用户每一笔买卖产生的、本该进入金库的钱。

**本金库从税里抽 0%。** 收到的税 100% 进入仓位,项目方在这一层拿零。

项目方的 40% 分的是**仓位在市场上赚到的收益**:那笔钱在仓位建立之前不存在,不来自任何一个
用户的口袋,也不是从金库本金里切出来的。仓位没有收益时,项目方收入为零。

| | 税这一层 | 收益这一层 |
|---|---|---|
| Flap commission 推荐(2% 税下) | ~3% | — |
| **本金库项目方** | **0%** | 40% |
| **本金库持有者** | — | **60%** |

### 我们据此请求的理由

1. **不与 commission 机制竞争。** `commissionReceiver` 是发币参数,本 factory 完全不触碰。
   Flap 若要对本金库发行的代币启用 commission,不受本设计任何阻碍。
2. **只在创造之后分配,不在流转中抽取。** 项目方拿不到任何一笔"因为有人交易而产生"的钱。
3. **与持有者严格同向,且持有者永远拿更多。** 每一次分配持有者 60%、项目方 40%,持有者恒为
   项目方的 **1.5 倍**。项目方无法在不同时把 1.5 倍交给持有者的前提下多拿一分。
4. **两个数都是 `constant` 且无 setter。** 部署后任何人(含项目方、含 Guardian)都无法调整,
   除非重新部署一套新 factory 并由 Flap 重新注册。

**是否接受由 Flap 判断。** 若 Flap 要求调整,我们改代码重新部署,不请求例外。

## 我方已完成

- [x] `LeverVaultFactory` 继承 `VaultFactoryBaseV2`(**spec v2.2**),`newVault` 仅 VaultPortal
- [x] `LeverBeacon` 构造函数即把 owner 转给 Flap Guardian(Rule 009 代理豁免的前提)
- [x] `vaultUISchema()` 覆盖全部 6 个用户可见方法,**方法名逐个与编译期 selector 比对**
- [x] `_validateBeforeLaunch`(v2.2 路径)拒绝本金库无法服务的发币参数:非 BNB 计价、
      非 WBNB 分红、零税、`vaultBps == 0`、`dividendBps == 0`
- [x] `receive()` 冷 57,433 / 热 9,133 gas,对 Rule 005 上限余量 94%,且 1 wei 与 0 value 均不 revert
- [x] 定时回调 1,206,637 gas,对 Rule 008 上限余量 40%;先买时间片再做工作,失败不断链条
- [x] 零 custom error,全部 revert 为中英内联字面量(Rule 004)
- [x] 无任何特权角色可改滑点/路由/时机/触发(Rule 003)
- [x] **59 项验证全绿**:24 个 forge 测试 + 33 条主网活状态断言(`bash scripts/test.sh`)
- [x] 编译参数固定,全部合约在 EIP-170 之内

## 待 Flap

- [ ] **裁定 SB-01**(40% 收益分成)
- [ ] 确认 `v2.2` 是提交基线(skill 内置 prelude 为 v2.1,与根目录不一致)
- [ ] 部署后由持有 `VAULT_ADMIN_ROLE` 的账户注册 factory

## 我方待办(拿到裁定后)

- [ ] 冻结 commit,重跑全部测试与 size gate
- [ ] 部署 factory 至 BSC 主网,交付地址

---

## 如何复现我们的数字

```bash
forge build && bash scripts/test.sh
```

其中 33 条断言以**单次原子 `eth_call`** 打在 BNB Chain 当前状态上(state override 注入探针
字节码),**不广播、不使用私钥、不需要 archive 节点**。选择这个形态的原因写在 `AUDIT.md`:
仓位路径需约 50 秒,而 BSC 约 96 秒即修剪状态且无免费 archive,fork 套件会中途以
`missing trie node` 死掉——直接 fork 与本地 anvil 缓存均已验证。

## 已知外部依赖

Venus Core Pool、PancakeSwap V3、Flap VaultPortal / TriggerService / dividendContract。
任一失效都会影响金库。**本设计移除的是"运营方私钥"这一信任对象,不是全部信任。**
