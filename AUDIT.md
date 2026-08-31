# LeverVault — Flap 十条规则自审报告

**被审对象**：`src/flap/LeverVault.sol`、`src/flap/LeverVaultFactory.sol`、`src/flap/LeverBeacon.sol`
**日期**：2026-08-31 · **链**：BNB Chain (56) · **状态**：factory 已上主网 `0xE7EC91f5a78c413cDF2F1140B29d51cAfFAfE535`,**未发任何代币**

> 这是一份**自审**报告,不是第三方审计。反复地自己对抗自己审查不是审计,本文也不会把它叫做审计。

---

## 结论先行

十条规则中 **007（AI Oracle）和 010（ERC-20 quote 记账）不适用**,其余八条自审通过。
`receive()` 冷路径 57,433 gas、热路径 9,133 gas,对 Rule 005 的 1,000,000 上限余量 94%。
自动结算回调实测 **1,206,637** gas,对 Rule 008 的 2,000,000 上限余量 **40%**。

---

## 机制与安全不变量

### 税只记账,不干活
`receive()` 做两次 SSTORE 加一个事件,没有循环、外部调用或 delegatecall。这不是风格选择:
`WBNB.withdraw()` 和 `vBNB.redeemUnderlying()` 都用 2,300 gas 的 stipend 回款
(`PUSH2 0x08fc`,从两份字节码读出,非推测),而两次 SSTORE 就是 9,133 gas。开发期间这条
路径曾以**空 returndata** 整条打死建仓流程。现在按 `msg.sender` 早退,同时修正了一个记账
错误——赎回回来的是本金,不是新税收。

### 杠杆上限由抵押率决定,不是产品选择
`health = supply × CF / debt`,Venus 在 1.00 清算。CF 80% 时 `最大杠杆 = h/(h−CF)`,
health 地板 1.20 对应上限 **3.00x**;**5x 算出来正好 1.00,即清算点本身**。构造函数拒绝
抵押率撑不住的目标,`_build` 按地板限债而不是按 Venus 自己的上限。开发期间曾发行过 5x,
实测落在 4.72x / health 1.015——BNB 跌 1.5% 全仓没了。该配置已被合约层面禁止。

### 减仓永不破地板
`_maxRedeemableBnb()` 解 `(s − x)·cf ≥ h·b`,按**健康度地板**而不是清算线计算可赎回量。
早期按清算线计算时,一次 0.99 BNB 的收益释放了 3.88 BNB 并把 health 打到 1.003。
`harvest` 与 `rebalance` 均有后置断言 `healthBps() >= MIN_HEALTH_BPS`。

### 收益与本金分离
`_shrinkBy` 的两个目标都取自**原始**两条腿。早期用循环后的 supply 重算目标,把循环已赎回
的部分又扣了一次,0.99 的收益释放了 1.90。修复后实测释放额与收益之比为 **1.00x**(三个规模)。

### 发币参数在创建前就被校验
`_validateBeforeLaunch`(spec v2.2 路径)拒绝五类本金库永远无法服务的代币:非 BNB 计价、
非 WBNB 分红、零税、`vaultBps == 0`、`dividendBps == 0`。**这不是洁癖**:`harvest()` 要求分红合约收 WBNB,一个用 BTCB 分红
的代币会正常建仓、正常增值,然后**永远无法把收益分给任何人**——金库越涨越大,持有者一分拿不到,
且发币后不可修复。零税代币同理,金库会被创建然后永远收不到钱。两者都在发币前一步拦掉。

### 分账不可变
`PROJECT_SHARE_BPS = 3000`,持有者 70% / 项目方 30%,均为 `constant`,**无 setter**。
项目方无法移动自己那份。赏金、滑点余量、路由费率档、结算间隔同样全部是常数。

---

## Flap 十条规则

| 规则 | 结论 | 依据 |
|---|---|---|
| **001** Base / UI schema / Guardian / No-DoS | ✅ | 继承 `VaultBaseV2`;`vaultUISchema()` 覆盖全部 6 个用户可见方法,且**名字逐个与编译期 selector 比对**(`test_everySchemaMethodNameResolvesToARealSelector`);合约无任何 role-gated 函数,故不存在可把 Guardian 锁在门外的角色。Guardian 的权限是它所有的 beacon。 |
| **002** Factory / commission | ⚠️ 见 SB-01 | **spec `v2.2`**。 `LeverVaultFactory` 继承 `VaultFactoryBaseV2`;`newVault` 拒绝一切非 VaultPortal 调用并逐项校验参数(5 个 revert 全部有测试);`vaultDataSchema()` 与 `newVault` 的 `vaultData` ABI 一致(一个 address);`isQuoteTokenSupported` 只认原生 BNB;发币校验走 v2.2 的 `_validateBeforeLaunch`——**v2.2 已废弃 `onBeforeNewTokenV6WithVault`,基类对它直接 revert,写在旧钩子上的守卫会静默失效**;有回归测试钉死这一点。`commissionReceiver` 是**发币参数**不是 factory 字段,commissionBps 由 launcher 按税率内部计算,本 factory 不触碰。**但 30% 的项目方分成需要 Flap 书面接受,见 SB-01。** |
| **003** 公平性 / 三明治 | ✅ | 三个工作函数全部无许可。**没有任何特权角色能改滑点、路由、时机或触发条件**——它们全是 `constant`。自动路径不付赏金(触发费已从金库出),手动路径付固定 bps,内部人相对机器人无任何结构性优势。 |
| **004** 字面量错误 / 双语 | ✅ | **零 custom error**;全部 revert 为 `require()` + `unicode` 中英内联字面量。开发期违反过此条,已全部替换。 |
| **005** `receive()` gas | ✅ | 冷 **57,433** / 热 **9,133**,上限 1,000,000。另有测试证明 1 wei 与 0 value 均不 revert,以及在 **2,300 gas stipend** 下对已知发送方仍然成功。 |
| **006** 集成测试 | ✅ | **28 个 forge 测试 + 33 条实测断言,全绿**。forge 覆盖 schema、factory 全部守卫、beacon 归属、初始化、trigger 授权与重放、三个工作函数的 revert 路径、stipend 守卫、gas 预算;`tools/verify.py` 覆盖仓位生命周期,以原子 `eth_call` 打在主网当前状态上。两者都有断言与退出码。见下节的形态说明。 |
| **007** AI Oracle | N/A | 不使用。 |
| **008** Trigger Service | ✅ | 校验 `msg.sender` 为唯一官方服务地址;requestId 在任何工作前被消费,重放被拒;每一次唤醒都重读链上状态再决定,不假设回调准时。**先买下一个时间片,再把工作放进 try**,所以一次失败不会断掉本可重试它的链条。实测回调 **1,206,637** gas,上限 2,000,000,余量 40%。 |
| **009** Emergency Controls | ✅ | BeaconProxy 部署,**按规则豁免**紧急提取函数并刻意不实现。豁免的前提是升级权限归 Guardian——`LeverBeacon` 构造函数即 `_transferOwnership(guardian)`,有测试断言部署者不保留权限。 |
| **010** ERC-20 quote 记账 | N/A | 不实现 `vaultQuoteToken()`;计价资产是原生 BNB。 |

---

## 验证形态:两半,都是断言

仓位相关的路径要走多步 Venus 与 PancakeSwap 状态,墙上时间约 50 秒。**BSC 公共节点约 96 秒
即修剪状态,且不存在免费 archive 节点**,fork 会在套件跑到一半时以 `missing trie node` 死掉。
直接 fork 与本地 anvil 缓存两种方式都验证过,结果相同。**这不是可以靠更好的写法绕开的问题。**

所以这部分改用 `tools/verify.py`:**33 条断言,每一条都是一次原子 `eth_call`**,探针字节码
由 state override 注入,打在主网当前状态上。有 PASS/FAIL,有退出码,和 forge 套件一样能进 CI。

这个形态在三点上**强于** fork,不是它的替代品:

- **打在当前状态上**,不是某个历史快照。价格、抵押率、池深都是此刻的真实值。
- **原子执行**,不可能被中途的状态漂移或节点不一致污染。fork 恰恰会——`bsc-dataseed` 是
  负载均衡的多节点,五次调用曾跨 19 个块。
- **零特殊依赖**。审计者用任意公共 RPC 一条命令复现,不广播、不用私钥、不需要 archive 节点。

`test/LeverVaultPosition.t.sol` 保留了 fork 版本,默认跳过,有 archive RPC 时以
`KEEL_ARCHIVE=1` 开启,作为交叉验证。

覆盖矩阵:

| 路径 | forge | 探针 |
|---|:--:|:--:|
| schema / factory 守卫 / beacon 归属 | ✅ 9 | — |
| 初始化 / trigger 授权 / 重放 / 三个工作函数 revert 路径 / stipend | ✅ 13 | — |
| `receive()` gas 预算 | ✅ 2 | ✅ |
| 建仓到目标杠杆与健康度(三个规模) | 可选 | ✅ 12 条断言 |
| 收割:释放额=收益、70/30 分账、健康度不降 | 可选 | ✅ 10 条断言 |
| 自动结算:买时间片、授权、重放、回调 gas | 可选 | ✅ 11 条断言 |
| 假 vault / 出身校验(自建版) | — | ✅ `tools/e2e.py` |

```
$ bash scripts/test.sh
 13 passed   offline: schema, factory guards, beacon ownership
 13 passed   forked:  authorization, guards, receive stipend
  2 passed   forked:  receive gas budget (rule 005)
      skipped forked:  position lifecycle — needs an archive RPC, see below
 33 passed   live:    build / harvest / automatic settlement
  8 passed   vault UI: ABI currency and i18n coverage
             sizes:   all deployable contracts within EIP-170
$ echo $?
0
```

裸 `forge test`(不带 `--fork-url`)同样退出 0:需要主网状态的套件在自己的 `setUp` 里
`vm.createSelectFork`,不依赖命令行参数。共 29 个测试通过、1 个按设计跳过。

---

## 测试环境的一个坑(会让套件间歇性变红)

`bsc-dataseed` 是**负载均衡的多节点**,高度不一致——连续五次调用曾跨 **19 个块**。forge 在
某个节点报的高度上 fork,却从另一个节点读状态,于是 Venus 记录的计息块号**领先于** fork 块,
Compound 的 `currentBlockNumber - accrualBlockNumberPrior` 下溢,`accrueInterest()` 随机
revert `math error`。

**把 fork 往回退是错的修法**(退得越远越容易下溢);正确做法是在每个 fork 测试的 `setUp` 里
`vm.roll` 向前推,越过任何节点可能记录的高度。三轮连跑全绿。

## 编译与 EIP-170

| 合约 | runtime | 余量 |
|---|---:|---:|
| `LeverVault` | 19,462 | 5,114 |
| `LeverVaultFactory` | 6,476 | 18,100 |
| `LeverBeacon` | 785 | 23,791 |

`LeverVaultFactory` 的 initcode 为 27,668 字节,在 EIP-3860 的 49,152 之内。

三个测试探针 `FlapProbe`(30,081)、`KeelProbe`(27,451)、`KeelE2E`(46,100)超过 24,576。它们由
`eth_call` state override 注入,永不部署,因此不受 EIP-170 约束;`scripts/test.sh` 的尺寸门
对它们放行、对任何可部署合约失败。

---

## Gas 预算

Venus 的 ResilientOracle 一次 `getUnderlyingPrice` 要 **26,308** gas(它要查多个价源),
`markets()` 取抵押率另需 17,879。建仓路径原本沿途反复重读同样的价格:四个 view 各调一次
就烧掉 422,477。

现在两个价格与抵押率**一次读出、全程传递**,连闪电贷回调也从 calldata 里取而不是重读。
效果:

| | 优化前 | 优化后 |
|---|---:|---:|
| `deployPending` 端到端 | 1,420,949 | **1,134,531** |
| 自动结算回调 | 1,510,777 | **1,206,637** |
| 对 2,000,000 上限的余量 | 24% | **40%** |
| `LeverVault` runtime | 20,060 | 19,462 |

行为未变:三个规模实测仍是 2.960x / health 1.208 / 待部署归零。

`_accrue()` 保留(vBNB 37,950 + vUSDT 28,558)。跳过它可以再省 66k,但那样健康度判断会
读到上一次计息时的债务,**偏乐观**——这 66k 买的是不朝危险那侧犯错。

## 提交阻断项

### SB-01 — 项目方 30% 分成需要 Flap 书面接受

Flap 对 factory commission 的推荐在 2% 税率下约为 **3%**。参考实现 ShiftVault 的 30% project
share 已被其自审标为提交阻断,本金库的 30% 更高。

**这是两层不同的钱。** Flap 的 commission 抽的是税——用户交易产生的、本该进金库的钱;
本金库**从税里抽 0%**,收到的税 100% 进仓位。项目方的 30% 分的是仓位在市场上赚到的收益,
那笔钱在建仓前不存在,不来自任何用户,仓位不赚钱时项目方收入为零。

| | 税这一层 | 收益这一层 |
|---|---|---|
| Flap commission 推荐(2% 税下) | ~3% | — |
| 本金库项目方 | **0%** | 30% |
| 本金库持有者 | — | **70%** |

请求理由:不与 commission 机制竞争(`commissionReceiver` 本 factory 不触碰);只在创造之后
分配,不在流转中抽取;与持有者严格同向且持有者恒为 1.5 倍。完整论证见 `SUBMISSION.md`。
**是否接受由 Flap 判断。**

两条都是 `constant` 且无 setter,若 Flap 要求调整,只能改代码重新部署。

### SB-02 — factory 必须先部署,注册权在 Flap

`registerVaultFactory` 需要 `VAULT_ADMIN_ROLE`,只有 Flap 能调。提交流程是:
**先把 factory 部署到 BSC 主网 → 把地址交给 Flap → 由 Flap 注册**。
factory 已于 block 119,107,358 部署至 BNB Chain:

| | 地址 | runtime |
|---|---|---:|
| `LeverVaultFactory` | `0xE7EC91f5a78c413cDF2F1140B29d51cAfFAfE535` | 6,476 |
| `LeverBeacon` | `0xA6B787FED6b42CbC772017A3F5d60fd988A364da` | 785 |
| `LeverVault`(implementation) | `0x8D5Ca13bf1D3DCe1f210bb3Ab733A95Da37640b2` | 19,462 |

链上读回的 `beacon.owner()` 是 `0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b`,即 Flap 的 BNB Chain
Guardian——**在 `LeverBeacon` 构造函数里就转出,部署者从未持有过升级权**。这是 Rule 009 代理豁免
的前提,现在是链上事实而非文档声明。

余下的是 Flap 侧动作:由持有 `VAULT_ADMIN_ROLE` 的账户调用 `registerVaultFactory`。

## 待处理项(部署前)

1. **第三方审计尚未进行。**
2. 触发费(0.0002 BNB/次)在冷清行情下持续消耗金库。已用 `IDLE_INTERVAL = 1 hours` 缓解,
   但极低成交量的代币仍会缓慢失血。

---

## 已知外部依赖

Venus Core Pool(借贷与清算)、PancakeSwap V3(兑换与闪电贷)、Flap VaultPortal(创建)、
Flap TriggerService(唤醒)、Flap dividendContract(分红)。任何一个失效都会影响金库。
**本设计移除的是"运营方的私钥"这一信任对象,不是全部信任。**

---

## Disclaimer

本文由合约作者自己产出,包含 AI 生成内容,必须由人类审计者复核。它不保证不存在缺陷。
