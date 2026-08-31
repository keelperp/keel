# Keel — Flap Vault UI 包

四个文件,对应 Flap Vault UI 模板要求的 `Component.tsx` / `manifest.json` / `VaultABI.ts` / `i18n.json`。

## 为什么不在这里打包

Flap 只接受 `yarn vault:package <folder>` 产出的 zip:包内带 format-version 6 的
`flap-vault-package.json` marker、`@flapsdk/vault-runtime` 的 gitHead provenance、递归源码/schema/E2E
文件哈希和 `qa/e2e-report.json`。**Workbench 会拒绝手工组装的 zip**,所以本目录不产出 zip,
也不该产出。

而 scaffold 与 manifest 都需要**真实部署的地址**:`match.bindings` 要 factory 或 vault 地址,
并且至少一个 binding 需要一个真实部署的 `7777` 后缀代币供 Workbench/E2E 测试。
**因此打包这一步必然排在合约部署之后。**

## 现在的状态(2026-08-31)

factory 已部署到两条链,`manifest.json` 的两个 binding 都已填真实地址:

| | |
|---|---|
| `LeverVaultFactory`(56 与 97 同址) | `0x8666262877046df9f4B338B9D7f1a30d55688A5c` |
| `artifactId` | 待 Workbench 分配,我们给不了 |
| 真实 `7777` 代币 | **不存在**,且测试网上造不出来 |

最后一行是 `yarn vault:package` 的硬前提。测试网无法创建金库:建仓必须闪电贷,而 BSC 测试网
的 PancakeSwap V3 是空的(32 个 WBNB 组合 `getPool` 全返回零地址,最近 40,000 块无 `PoolCreated`),
两个测试 USDT 的 `mint` 又都是 `Ownable` 且 owner 是他人,连池子都建不了。详见
`../submission/UI-REQUEST.md` 与 `../AUDIT.md`。

因此本目录交付的是**四个源文件**,不是 zip。真正的包必须在拿到 `artifactId` 和一个真实代币之后,
在 Flap 模板仓库里由 `yarn vault:package` 产出。

## 部署之后怎么做

1. 在 Flap 的 Vault UI 模板仓库里 scaffold 一个包:

   ```bash
   yarn vault:scaffold keel --name "Keel" --chain 97 --factory 0x<测试网Factory> \
     --token 0x<真实7777测试代币> --chain 56 --factory 0x<主网Factory> --locales en,zh
   ```

2. 用本目录的四个文件覆盖 scaffold 出来的同名文件。
3. 把 `manifest.json` 里三个 `REPLACE_` 占位换成真实地址,`artifactId` 用 Workbench 分配的。
4. 本地预览走真实路由,确认读数与链上一致。
5. 依次跑 `yarn vault:check keel` → `yarn vault:e2e keel` → `yarn vault:package keel`,提交产出的 zip。

## ABI 是生成的,不是手写的

`VaultABI.ts` 由 `tools/gen-vault-abi.mjs` 从 forge 产物生成,并**裁剪到组件真正调用的那些名字**。
脚本在任何一个名字不存在于 `LeverVault` 时直接中止——手写切片会在签名改动的那一刻静默漂移,
而只比对参数个数的门看不见类型漂移。合约一改就重跑:

```bash
forge build && node tools/gen-vault-abi.mjs
```

## 组件遵守的边界

- 所有读取走 `context.vaultAddress`,不硬编码任何地址;
- 未加载的值渲染成破折号,**不当作 0**——这是一个会让人据此决定投多少钱的界面;
- 健康度刻度是静态 SVG 几何,位置由 React state 给出,**无文字节点、无外部引用**;
- 不带字体文件(包里只允许那四个文件),字体栈只点名、由系统兜底;
- 组件不发起任何对外请求。

## 页面主角是"它自己在转"

首屏是**下一次结算的倒计时**和**这次会做什么**,不是按钮。三个工作函数和 `kickstart` 放在
第二张卡片里,标题就叫手动兜底——因为在正常情况下没有人需要按它们。
