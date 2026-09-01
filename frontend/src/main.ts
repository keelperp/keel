import { formatUnits } from "viem";
import { publicClient, loadManifest, type Manifest, type Maybe } from "./chain";
import { LevVaultAbi, BondingAbi } from "./generated/abi";

const app = document.getElementById("app")!;

/** Live numbers for one vault. Every field is nullable: a value that has not been read
 *  is not zero, and a payment surface must never round "unknown" down to 0. */
type VaultView = {
  address: `0x${string}`;
  symbol: Maybe<string>;
  exchangeRate: Maybe<bigint>;
  leverage: Maybe<bigint>;
  target: Maybe<bigint>;
  health: Maybe<bigint>;
  totalAssets: Maybe<bigint>;
  needsRebalance: Maybe<boolean>;
  bountyBps: Maybe<bigint>;
};

const x18 = (v: Maybe<bigint>, dp = 2) => (v === null ? "—" : Number(formatUnits(v, 18)).toFixed(dp));
const usd = (v: Maybe<bigint>) =>
  v === null ? "—" : Number(formatUnits(v, 18)).toLocaleString(undefined, { maximumFractionDigits: 2 });

/** Names viem must see as literals, not as `string` — otherwise the return type is
 *  unknown and a signature drift compiles clean. */
type VaultFn =
  | "symbol"
  | "exchangeRate"
  | "currentLeverage"
  | "targetLeverage"
  | "healthBps"
  | "totalAssets"
  | "needsRebalance";

async function readVault(address: `0x${string}`): Promise<VaultView> {
  const call = <T,>(functionName: VaultFn) =>
    publicClient
      .readContract({ address, abi: LevVaultAbi, functionName })
      .then((r) => r as T)
      .catch(() => null);

  const [symbol, exchangeRate, leverage, target, health, totalAssets, needsRebalance] = await Promise.all([
    call<string>("symbol"),
    call<bigint>("exchangeRate"),
    call<bigint>("currentLeverage"),
    call<bigint>("targetLeverage"),
    call<bigint>("healthBps"),
    call<bigint>("totalAssets"),
    call<boolean>("needsRebalance"),
  ]);

  let bountyBps: Maybe<bigint> = null;
  if (leverage !== null) {
    bountyBps = await publicClient
      .readContract({ address, abi: LevVaultAbi, functionName: "bountyBps", args: [leverage] })
      .then((r) => r as bigint)
      .catch(() => null);
  }

  return { address, symbol, exchangeRate, leverage, target, health, totalAssets, needsRebalance, bountyBps };
}

function vaultCard(v: VaultView): string {
  // Health is capped for display: an unlevered vault reads type(uint256).max.
  const healthTxt =
    v.health === null ? "—" : v.health > 10n ** 9n ? "no debt" : (Number(v.health) / 10000).toFixed(3);
  const drift = v.needsRebalance === true;
  return `
    <div class="card">
      <h3>${v.symbol ?? "—"} ${drift ? `<span class="pill warn">drifted</span>` : ""}</h3>
      <dl>
        <div class="row"><dt>Share price</dt><dd>${x18(v.exchangeRate, 4)} USDT</dd></div>
        <div class="row"><dt>Leverage</dt><dd>${x18(v.leverage)}× / ${x18(v.target)}×</dd></div>
        <div class="row"><dt>Health</dt><dd>${healthTxt}</dd></div>
        <div class="row"><dt>Vault size</dt><dd>${usd(v.totalAssets)} USDT</dd></div>
        ${drift ? `<div class="row"><dt>Rebalance pays</dt><dd>${v.bountyBps ?? "—"} bps</dd></div>` : ""}
      </dl>
      <p style="margin:12px 0 0"><code>${v.address}</code></p>
    </div>`;
}

function chrome(body: string, route: string): string {
  const link = (href: string, label: string) =>
    `<a href="${href}" class="${route === href ? "on" : ""}">${label}</a>`;
  return `<div class="wrap">
    <nav>
      <strong>Keel</strong>
      ${link("/", "Vaults")}
      ${link("/launch", "Launch")}
      ${link("/about", "How it works")}
      <span class="sp"></span>
      <button id="connect">Connect wallet</button>
    </nav>
    ${body}
  </div>`;
}

function notDeployed(): string {
  return `
    <h1>Keel</h1>
    <p class="sub">Leveraged positions held on chain by the contract itself — no keeper account, no published NAV, no pause.</p>
    <div class="empty">
      <p><strong>Not deployed.</strong></p>
      <p>No contracts exist on BNB Chain yet, so there is nothing to show. This page will fill in
      the moment <code>./deploy</code> writes a manifest — it reads live state and shows nothing
      when there is none.</p>
    </div>`;
}

async function render() {
  const route = location.pathname;
  const manifest = await loadManifest();

  if (!manifest) {
    app.innerHTML = chrome(notDeployed(), route);
  } else if (route === "/launch") {
    const count = await publicClient
      .readContract({ address: manifest.bonding, abi: BondingAbi, functionName: "tokenCount" })
      .catch(() => null);
    app.innerHTML = chrome(
      `<h1>Launch a token</h1>
       <p class="sub">Pick the vault that backs it. That choice sets the market, the direction and the leverage.</p>
       <p style="margin-top:18px">Launches so far: <code>${count === null ? "—" : String(count)}</code></p>`,
      route
    );
  } else if (route === "/about") {
    app.innerHTML = chrome(
      `<h1>How it works</h1>
       <p class="sub">Each vault is an ERC-20 claim on a Venus position the contract holds itself.
       Its share price is a view over chain state, not a number someone publishes, so it cannot go
       stale and it cannot be switched off.</p>
       <h2>What can go wrong</h2>
       <p class="sub">A 3× position is liquidated by a 16.7% move against it. Venus and PancakeSwap
       are dependencies. Submitted to Flap for review; no third-party security audit.</p>`,
      route
    );
  } else {
    const views = await Promise.all(manifest.vaults.map((v) => readVault(v.address)));
    const live = views.filter((v) => v.symbol !== null);
    app.innerHTML = chrome(
      `<h1>Vaults</h1>
       <p class="sub">Every figure below is read from BNB Chain when this page loads.</p>
       ${
         live.length === 0
           ? `<div class="empty">The manifest lists ${manifest.vaults.length} vaults but none answered. Check the RPC.</div>`
           : `<div class="grid">${live.map(vaultCard).join("")}</div>`
       }`,
      route
    );
  }

  document.getElementById("connect")?.addEventListener("click", async () => {
    const eth = (window as any).ethereum;
    if (!eth) {
      alert("No wallet found. Install a BNB Chain wallet to continue.");
      return;
    }
    await eth.request({ method: "eth_requestAccounts" });
  });
}

addEventListener("popstate", render);
document.addEventListener("click", (e) => {
  const a = (e.target as HTMLElement).closest("a");
  if (a && a.getAttribute("href")?.startsWith("/")) {
    e.preventDefault();
    history.pushState(null, "", a.getAttribute("href")!);
    render();
  }
});
render();
