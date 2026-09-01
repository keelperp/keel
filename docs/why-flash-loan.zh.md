# 为什么必须用闪电贷

> 回应一个常见疑问:"Venus 走预言机价格,V3 池子里买一点 BNB 推不动价格,那闪电贷是在解决什么?"
>
> 结论:闪电贷解决的不是滑点,是 **Venus 借款的时序约束**。就算池子深度无限、滑点为零、
> 预言机价格纹丝不动,不用闪电贷也一样建不起这个仓位——只能循环十几次慢慢逼近。
>
> 本文每一处代码引用都对应 `src/flap/LeverVault.sol` 的实际实现,费率档位为链上实测。

---

## 一、Venus 检查抵押品的时刻

Venus 是 Compound V2 的分叉。`borrow()` 在**执行的那一刻**校验账户的流动性,只认**已经
入账的抵押品**,不认这笔交易接下来还要存进来的钱。

于是"一次性借到位"这条路直接被堵死。代数上允许的一次借款额是:

```
(s·cf − h·b) / (h − cf)
```

其中 `s` 是当前抵押、`b` 是当前负债、`cf` 是抵押率 0.80、`h` 是健康度下限 1.20。
把这个数字直接丢给 Venus,它会以 `math error` 拒绝——因为那笔钱要等借出来之后才变成抵押。

**这跟价格无关。** 预言机报什么价、池子有多深、滑点是不是零,都不影响这个判断。

---

## 二、不用闪电贷会怎样

只能循环:

```
借 USDT → 换成 BNB → 存进 Venus → 再借更多 USDT → ...
```

每一轮只能按**当前已入账**的抵押去借,所以每轮增量按 `cf / h = 0.80 / 1.20 ≈ 0.667`
几何收敛。推算下来需要 **约 18 次** swap 才能摸到 3×,累计手续费约 **0.30%**。

> 口径说明:18 次与 0.30% 是按上述几何级数**推算**的,不是实测值。我们实测过的是闪电贷
> 路径(33 条主网活状态断言)。循环路径没有真跑过 18 轮去验证。

---

## 三、闪电贷做的事:把顺序倒过来

`pancakeV3FlashCallback` 的实际执行顺序:

```solidity
// 1. 把闪来的 WBNB 解包成原生 BNB(vBNB 只收原生币)
IWNative(WBNB).withdraw(borrowed);

// 2. 整笔存进 Venus —— 这一刻 Venus 一次性看到全额抵押
IVBNB(vBNB).mint{value: borrowed}();

// 3. 抵押已足额,一步借到位。多借 0.3% 兜住滑点与闪电贷费
uint256 usdtNeeded = owed * pxBnb / pxUsdt * 1003 / 1000;
require(IVToken(vUSDT).borrow(usdtNeeded) == 0, "Venus borrow failed / Venus 借款失败");

// 4. 换回 WBNB 并归还闪电贷
uint256 got = _swap(USDT, WBNB, usdtNeeded);
require(got >= owed, "flash repayment short / 闪电贷还款不足");
IERC20Min(WBNB).transfer(FLASH_POOL, owed);

// 换多了的部分解包成 BNB 留在合约,不浪费
if (got > owed) IWNative(WBNB).withdraw(got - owed);
```

**先 supply,后 borrow。** 一笔交易完成,一次 swap,不用循环。手续费降到约 **0.089%**,
`maxLoops` 从 18 降到 3。

---

## 四、两个池必须是不同费率档

V3 的池在自己的 flash 回调期间是**锁住的**。如果从同一个池借、又在同一个池里换,回调会以
`LOK` 回滚。

链上实测:

| | 地址 / 值 | 费率 |
|---|---|---|
| `FLASH_POOL` | `0x36696169C63e42cd08ce11f5deeBbCeBae652050` | `fee()` = **500**(0.05%) |
| swap | 经 `V3_ROUTER` | `SWAP_FEE` = **100**(0.01%) |

该池 token0 是 USDT、token1 是 WBNB(`0x55d3… < 0xbb4C…`),所以闪电贷借的是 `amount1`。
池内 WBNB 余额约 **7,439 枚**,深度充足。

这条不变量已写进 `submission/check`,对着节点核验,同档就报错。

---

## 五、关于滑点,把话说清楚

提问里那句"V3 买一点 BNB 推不动价格"是对的,但那是**另一个独立问题**。两件事分开说:

**时序**(本文主题):闪电贷解决的。跟滑点无关。

**滑点**:这个合约**没有滑点参数**。`_swap` 提交的是:

```solidity
amountOutMinimum: 0,
sqrtPriceLimitX96: 0
```

代替它的是**建仓路径上的一道事后检查**:`require(got >= owed)`。被夹到还不上闪电贷,
整笔交易回滚。

**但减仓路径没有这道保护。** `harvest` 与 `rebalance` 走的是:

```solidity
uint256 pay = usdt < debt - debtTarget ? usdt : debt - debtTarget;
```

换回来少了就少还,不会回滚。这是对所有调用方开放的 MEV 暴露(不是特权方独有),我们在
提交文档里按披露处理,而不是说成"滑点是常量"。

---

## 六、一句话总结

| | 循环路径 | 闪电贷路径 |
|---|---|---|
| 为什么可行 | 每轮只借当前抵押撑得住的一小块 | 先存满,再一次借到位 |
| swap 次数 | 约 18(推算) | **1** |
| 手续费 | 约 0.30%(推算) | **0.089%** |
| 受阻于 | Venus 的"先存后借" | — |

**闪电贷不是优化,是这条路上唯一可行的顺序。**
