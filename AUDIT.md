# LeverVault — Flap 十条规则自审报告

**被审对象**：`src/flap/LeverVault.sol`、`src/flap/LeverVaultFactory.sol`、`src/flap/LeverBeacon.sol`
**日期**：2026-08-29 · **链**：BNB Chain (56) · **状态**：`NOT_DEPLOYED`,从未向任何网络广播

> 这是一份**自审**报告,不是第三方审计。反复地自己对抗自己审查不是审计,本文也不会把它叫做审计。

---

## 结论先行

十条规则中 **007（AI Oracle）和 010（ERC-20 quote 记账）不适用**,其余八条自审通过。
`receive()` 冷路径 57,433 gas、热路径 9,133 gas,对 Rule 005 的 1,000,000 上限余量 94%。
自动结算回调实测 1,510,777 gas,对 Rule 008 的 2,000,000 上限**余量仅 24%**——这是本合约
最紧的一根弦,列在下方待处理项第一位。

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

### 分账不可变
`PROJECT_SHARE_BPS = 4000`,持有者 60% / 项目方 40%,均为 `constant`,**无 setter**。
项目方无法移动自己那份。赏金、滑点余量、路由费率档、结算间隔同样全部是常数。

---

## Flap 十条规则

| 规则 | 结论 | 依据 |
|---|---|---|
| **001** Base / UI schema / Guardian / No-DoS | ✅ | 继承 `VaultBaseV2`;`vaultUISchema()` 覆盖全部 6 个用户可见方法,且**名字逐个与编译期 selector 比对**(`test_everySchemaMethodNameResolvesToARealSelector`);合约无任何 role-gated 函数,故不存在可把 Guardian 锁在门外的角色。Guardian 的权限是它所有的 beacon。 |
| **002** Factory / commission | ✅ | `LeverVaultFactory` 继承 `VaultFactoryBaseV2`;`newVault` 拒绝一切非 VaultPortal 调用并逐项校验参数(5 个 revert 全部有测试);`vaultDataSchema()` 与 `newVault` 的 `vaultData` ABI 一致(一个 address);`isQuoteTokenSupported` 只认原生 BNB。 |
| **003** 公平性 / 三明治 | ✅ | 三个工作函数全部无许可。**没有任何特权角色能改滑点、路由、时机或触发条件**——它们全是 `constant`。自动路径不付赏金(触发费已从金库出),手动路径付固定 bps,内部人相对机器人无任何结构性优势。 |
| **004** 字面量错误 / 双语 | ✅ | **零 custom error**;全部 revert 为 `require()` + `unicode` 中英内联字面量。开发期违反过此条,已全部替换。 |
| **005** `receive()` gas | ✅ | 冷 **57,433** / 热 **9,133**,上限 1,000,000。另有测试证明 1 wei 与 0 value 均不 revert,以及在 **2,300 gas stipend** 下对已知发送方仍然成功。 |
| **006** 集成测试 | ⚠️ 部分 | **24 个 forge 测试全绿**,覆盖 schema、factory 全部守卫、beacon 归属、初始化、trigger 授权与重放、三个工作函数的 revert 路径、stipend 守卫、gas 预算。**仓位生命周期(建仓/收割/自动结算)因链上约束无法用 fork 覆盖**,见下节。 |
| **007** AI Oracle | N/A | 不使用。 |
| **008** Trigger Service | ✅ | 校验 `msg.sender` 为唯一官方服务地址;requestId 在任何工作前被消费,重放被拒;每一次唤醒都重读链上状态再决定,不假设回调准时。**先买下一个时间片,再把工作放进 try**,所以一次失败不会断掉本可重试它的链条。实测回调 **1,510,777** gas,上限 2,000,000。 |
| **009** Emergency Controls | ✅ | BeaconProxy 部署,**按规则豁免**紧急提取函数并刻意不实现。豁免的前提是升级权限归 Guardian——`LeverBeacon` 构造函数即 `_transferOwnership(guardian)`,有测试断言部署者不保留权限。 |
| **010** ERC-20 quote 记账 | N/A | 不实现 `vaultQuoteToken()`;计价资产是原生 BNB。 |

---

## Rule 006 的例外,以及为什么

仓位相关的测试要走多步 Venus 与 PancakeSwap 状态,墙上时间约 50 秒。**BSC 公共节点约 96 秒
即修剪状态,且不存在免费 archive 节点**,fork 会在套件跑到一半时以 `missing trie node` 死掉。
直接 fork 与本地 anvil 缓存两种方式都验证过,结果相同。

这些测试保留在 `test/LeverVaultPosition.t.sol`,默认跳过,有 archive RPC 时以
`KEEL_ARCHIVE=1` 开启。

**同一批路径由 `tools/flap.py` 覆盖**:它把完整生命周期作为**一次原子 `eth_call`** 打在
真实主网当前状态上,因此不受修剪影响,而且比 fork 更接近现实。审计者不需要 archive 节点也能
复现——一条命令,只读链,不广播。

覆盖矩阵:

| 路径 | forge | 探针 |
|---|:--:|:--:|
| schema / factory 守卫 / beacon 归属 | ✅ 9 | — |
| 初始化 / trigger 授权 / 重放 / 三个工作函数 revert 路径 / stipend | ✅ 13 | — |
| `receive()` gas 预算 | ✅ 2 | ✅ |
| 建仓到目标杠杆与健康度 | ⚠️ archive | ✅ `tools/flap.py` |
| 收割 60/40 分账、释放额=收益 | ⚠️ archive | ✅ `tools/flap.py` |
| 自动结算完整回调 | ⚠️ archive | ✅ `tools/flap.py` |
| 假 vault / 出身校验(自建版) | — | ✅ `tools/e2e.py` |

---

## 编译与 EIP-170

| 合约 | runtime | 余量 |
|---|---:|---:|
| `LeverVault` | 20,060 | 4,516 |
| `LeverVaultFactory` | 5,173 | 19,403 |
| `LeverBeacon` | 785 | 23,791 |

`LeverVaultFactory` 的 initcode 为 26,963 字节,在 EIP-3860 的 49,152 之内。

---

## 待处理项(部署前)

1. **回调 gas 余量只有 24%**(1,510,777 / 2,000,000)。Venus 状态若使 gas 上升,唤醒会失败。
   设计上失败不断链条且任何人可手动补,但这是最紧的一根弦。**建议在真金进入前压缩建仓路径。**
2. **仓位测试需要 archive RPC 才能进 CI。** 目前依赖探针,证据成立但形态不标准。
3. **第三方审计尚未进行。**
4. 触发费(0.0002 BNB/次)在冷清行情下持续消耗金库。已用 `IDLE_INTERVAL = 1 hours` 缓解,
   但极低成交量的代币仍会缓慢失血。

---

## 已知外部依赖

Venus Core Pool(借贷与清算)、PancakeSwap V3(兑换与闪电贷)、Flap VaultPortal(创建)、
Flap TriggerService(唤醒)、Flap dividendContract(分红)。任何一个失效都会影响金库。
**本设计移除的是"运营方的私钥"这一信任对象,不是全部信任。**

---

## Disclaimer

本文由合约作者自己产出,包含 AI 生成内容,必须由人类审计者复核。它不保证不存在缺陷。
