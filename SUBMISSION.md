# LeverVault — 提交给 Flap 的说明

**版本**:factory spec `v2.2` · solc 0.8.26 / Cancun / optimizer 200 / 无 viaIR
**状态**:factory 已部署至 BNB Chain(56)——`0x3f09f61D8460D330b7387e460FCcc3A90cCe4313`
**尚未发币**:代币由 Flap 自己的 launcher 经 VaultPortal 创建
**自审**:见 `AUDIT.md`(十条规则逐条)。**无第三方审计。**

---

## 这个金库做什么

代币的买卖税以原生 BNB 进入金库,金库把它建成一个 **3 倍 BNB 多头**,持仓在合约自己名下
(Venus 借贷,合约是借款人也是抵押人)。**Flap 的定时服务每 5 分钟唤醒一次**,金库按优先级
做一件事:救仓位 → 建仓 → 分配收益 → 再平衡。仓位赚到钱时,收益的 **70% 通过代币自己的
分红合约以 WBNB 发给持有者,30% 给项目方**。

没有 keeper 账户,没有对外公布的净值,没有暂停开关。`nav()` 是一个 view。

---

## SB-01:项目方 30% 分成,请求 Flap 书面裁定

### 这是两层不同的钱

Flap 的 factory commission 抽的是**税**——用户每一笔买卖产生的、本该进入金库的钱。

**本金库从税里抽 0%。** 收到的税 100% 进入仓位,项目方在这一层拿零。

项目方的 30% 分的是**仓位在市场上赚到的收益**:那笔钱在仓位建立之前不存在,不来自任何一个
用户的口袋,也不是从金库本金里切出来的。仓位没有收益时,项目方收入为零。

| | 税这一层 | 收益这一层 |
|---|---|---|
| Flap commission 推荐(2% 税下) | ~3% | — |
| **本金库项目方** | **0%** | 30% |
| **本金库持有者** | — | **70%** |

### 我们据此请求的理由

1. **不与 commission 机制竞争。** `commissionReceiver` 是发币参数,本 factory 完全不触碰。
   Flap 若要对本金库发行的代币启用 commission,不受本设计任何阻碍。
2. **只在创造之后分配,不在流转中抽取。** 项目方拿不到任何一笔"因为有人交易而产生"的钱。
3. **与持有者严格同向,且持有者永远拿更多。** 每一次分配持有者 70%、项目方 30%,持有者恒为
   项目方的 **2.33 倍**。项目方无法在不同时把 2.33 倍交给持有者的前提下多拿一分。
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
- [x] **100 项验证全绿**:59 个 forge 测试 + 33 条主网活状态断言 + 8 项 Vault UI 包检查
      (`bash scripts/test.sh`)。仓位生命周期一组测试按设计跳过——需要 archive RPC,BSC 没有免费的,
      同样的路径由那 33 条断言在主网当前状态上覆盖
- [x] 编译参数固定,全部**可部署**合约在 EIP-170 之内(`LeverVault` 23,193 / `LeverVaultFactory`
      runtime 7,745)。一个测试探针 `FlapProbe` 超过 24,576,它由
      `eth_call` state override 注入,永不部署

## Vault UI 包

`vault-ui/` 下是 Flap Vault UI 模板要求的四个文件:`Component.tsx`(首屏是**下一次结算的倒计时**
和这次会做什么,三个工作函数放在"手动兜底"卡片里)、`manifest.json`、`VaultABI.ts`、`i18n.json`
(中英双语)。

`VaultABI.ts` 由 `tools/gen-vault-abi.mjs` 从 forge 产物生成并裁剪到组件真正调用的名字;
`tools/check-vault-ui.mjs` 是回归门:重新生成必须是空操作、组件调用的每个名字都要在 ABI 里、
两种语言 key 必须一致、每个 `t()` 都要有定义。已接入 `scripts/test.sh`。

**本目录不产出 zip,也不该产出。** Flap 只接受 `yarn vault:package` 的产物(带 format-version 6
marker、runtime provenance、递归文件哈希与 `qa/e2e-report.json`),**手工组装的 zip 会被 Workbench
拒绝**。而 scaffold 与 `match.bindings` 都需要真实部署的 factory 地址和一个真实的 `7777` 代币,
**所以打包必然排在部署之后**。部署后的五步流程写在 `vault-ui/README.md`。

## 待 Flap

- [ ] **裁定 SB-01**(30% 收益分成)
- [ ] **确认是否要求测试网端到端**。factory 已部署至 97(与主网同址),但该链没有任何含
      WBNB 的 PancakeSwap V3 池(32 个组合实测全为零地址),而建仓必须闪电贷,故金库无法在
      测试网创建。详见 AUDIT.md「为什么没有测试网端到端」。若贵方有指定的测试环境或池,
      我们照跑。
- [ ] 确认 `v2.2` 是提交基线(skill 内置 prelude 为 v2.1,与根目录不一致)
- [ ] 部署后由持有 `VAULT_ADMIN_ROLE` 的账户注册 factory

## 发币参数

已定与待定逐项列在 `LAUNCH.md`。要点:2% 买卖税、**税的 80% 进金库建仓 / 20% 直接分红**、
税期 100 年(永久)、分红门槛 10,000 枚、原生 BNB 计价、`TOKEN_TAXED_V3`。
代币 **Keel / KEEL**,项目方地址取部署者钱包。

## 我方待办(拿到裁定后)

- [ ] 冻结 commit,重跑全部测试与 size gate
- [ ] 部署 factory 至 BSC 主网,交付地址
- [ ] 用真实地址填 `vault-ui/manifest.json`,在 Flap 模板仓库跑
      `vault:check` → `vault:e2e` → `vault:package`,提交 zip

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
