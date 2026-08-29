# 发币参数（`newTokenV6WithVault`）

一次性、发出去就改不了的东西。每一项标注来源:**硬**=Flap 协议强制,**门**=本 factory 会拒,
**决**=已拍板,**待**=还没定。

## 代币身份

| 字段 | 值 | 来源 |
|---|---|---|
| `name` | **待定** | 待 |
| `symbol` | **待定** | 待 |
| 总供应量 | `1,000,000,000` (1e27) | 硬 · Flap 固定,抽样三个线上代币均为此值 |
| `meta` | 待定(图标/描述) | 待 |

## 税

| 字段 | 值 | 来源 |
|---|---|---|
| `buyTaxRate` | `200` (2%) | 决 |
| `sellTaxRate` | `200` (2%) | 决 |
| `taxDuration` | `3153600000` (100 年,即永久) | 决 · 税一停,金库就只剩一个不再长大的存量仓位 |
| `antiFarmerDuration` | **待定** | 待 · Flap 上限 1 年;按房屋标准此类阈值不写进前端 |

## 税的四路分配（必须加起来 = 10000）

| 字段 | 值 | 去向 |
|---|---:|---|
| `mktBps` | **8000** | **金库**——拿去建 3 倍 BNB 多头。受益人就是金库合约 |
| `dividendBps` | **2000** | 直接进分红合约,持有者立刻可领,不依赖行情 |
| `deflationBps` | `0` | 不销毁 |
| `lpBps` | `0` | 不进 LP |
| | **= 10000** | 决 · V3 硬校验 |

八二开的取舍:金库那一份是"没人交易也在涨"的来源,直接分红那一份是持有者在行情不动时也
看得见的现金流。两者都要,20% 是给后者的分量。

## 分红

| 字段 | 值 | 来源 |
|---|---|---|
| `dividendToken` | `address(0)` | 门 · 等价于 quote(BNB),到分红合约是 WBNB;非 WBNB 会被 factory 拒 |
| `minimumShareBalance` | `10_000e18` | 硬 · 下限即此值,Flap 官方币同值。**低于此持仓拿不到分红** |

## 结构

| 字段 | 值 | 来源 |
|---|---|---|
| `tokenVersion` | `TOKEN_TAXED_V3` (6) | 硬 · 只有 V3 支持非对称税与自定义金库 |
| `quoteToken` | `address(0)` 原生 BNB | 门 |
| `dexThresh` | `FOUR_FIFTHS` (1) | 硬 · 实测其他值 revert `0x77146b42` |
| `migratorType` | `V2_MIGRATOR` (1) | 硬 · taxed V3 只能迁到 Uniswap V2 fork |
| `commissionReceiver` | `address(0)` | 决 · 本 factory 不触碰 commission,不与 Flap 机制竞争 |
| `vaultFactory` | 部署后填 | 待 |
| `vaultData` | `abi.encode(项目方地址)` | 门 · 该地址收 40% 收益份额,**发币后不可改** |
| `quoteAmt` | **待定** | 待 · 你自己的首笔买入 |
| `salt` | 挖 `7777` 后缀 | 硬 · 从高偏移开始搜,低位 salt 已被占 |

## 发出去就改不了的四件事

1. **`vaultData` 里的项目方地址**——金库没有 setter。
2. **四路 bps**——税的分配写死在代币里。
3. **税率与税期**。
4. **`minimumShareBalance`**——决定谁有资格拿分红。

## 金库这一侧的常数（同样不可改）

`TARGET_LEVERAGE` 3x · `MIN_HEALTH_BPS` 12000 · `PROJECT_SHARE_BPS` 4000(项目方 40% /
持有者 60%) · 结算间隔 5 分钟 / 空闲 1 小时 · 赏金 25/50/30 bps · 紧急线 health 1.10。
全部 `constant`,无 setter,改只能重新部署并请 Flap 重新注册。
