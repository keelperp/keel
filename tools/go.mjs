#!/usr/bin/env node
// Keel operator interface: deploy | lock | exit.
// Zero npm dependencies — every chain interaction shells out to `cast`, so there is
// nothing to install into a shared directory and nothing to drift.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DEPLOYMENTS = join(ROOT, "deployments");

function die(msg) {
  console.error(`\n  ABORT: ${msg}\n`);
  process.exit(1);
}

function env(name, { required = true } = {}) {
  const v = process.env[name];
  // A blank .env line is an empty string, not undefined — `??` does not catch it.
  if (required && (v === undefined || v.trim() === "")) die(`${name} is unset or empty`);
  return v === undefined ? "" : v.trim();
}

function cast(args, { quiet = false } = {}) {
  try {
    return execFileSync("cast", args, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
  } catch (e) {
    if (!quiet) die(`cast ${args.slice(0, 2).join(" ")} failed:\n${e.stderr || e.message}`);
    throw e;
  }
}

/** An address printed by a simulation is a guess. Only code on chain makes it real. */
function requireCode(label, addr, rpc) {
  if (!/^0x[0-9a-fA-F]{40}$/.test(addr || "")) die(`${label}: not an address (${addr})`);
  const code = cast(["code", addr, "--rpc-url", rpc]);
  if (code === "0x" || code === "") die(`${label} at ${addr} has NO CODE — the broadcast did not land`);
  console.log(`  ok  ${label.padEnd(14)} ${addr}  ${(code.length - 2) / 2} bytes`);
  return addr;
}

/** cast send returns a receipt on revert too. Status is the only truth.
 *  `fatal: false` throws instead of exiting, so a caller that must keep going
 *  (./exit) can skip one leg without skipping the rest of the command. `die()`
 *  is process.exit — a try/catch around a fatal send catches nothing. */
function send(to, sig, args, { rpc, pk, value, fatal = true }) {
  const argv = ["send", to, sig, ...args, "--rpc-url", rpc, "--private-key", pk, "--json"];
  if (value) argv.push("--value", value);
  const out = cast(argv, { quiet: !fatal });
  const receipt = JSON.parse(out);
  if (receipt.status !== "0x1" && receipt.status !== 1) {
    const msg = `tx reverted: ${receipt.transactionHash}`;
    if (fatal) die(msg);
    throw new Error(msg);
  }
  console.log(`  ok  ${sig.split("(")[0].padEnd(14)} ${receipt.transactionHash}`);
  return receipt;
}

function manifestPath(chainId) {
  return join(DEPLOYMENTS, `${chainId}.json`);
}

function loadManifest(chainId) {
  const p = manifestPath(chainId);
  if (!existsSync(p)) die(`no manifest at ${p} — run ./deploy first`);
  return JSON.parse(readFileSync(p, "utf8"));
}

// ---------------------------------------------------------------- deploy

function deploy() {
  if (env("CONFIRM") !== "KEEL") die("set CONFIRM=KEEL to deploy");
  const rpc = env("KEEL_RPC_URL");
  const pk = env("KEEL_DEPLOYER_KEY");
  const custody = env("KEEL_CUSTODY");

  const chainId = cast(["chain-id", "--rpc-url", rpc]);
  console.log(`\n  chain ${chainId}\n`);

  console.log("  broadcasting Deploy.s.sol ...");
  execFileSync(
    "forge",
    ["script", "script/Deploy.s.sol:Deploy", "--rpc-url", rpc, "--private-key", pk, "--broadcast", "-g", "300"],
    { cwd: ROOT, stdio: "inherit", env: { ...process.env, KEEL_CUSTODY: custody } }
  );

  // Read addresses back out of the artefact — never off the console.
  const runPath = join(ROOT, "broadcast", "Deploy.s.sol", chainId, "run-latest.json");
  if (!existsSync(runPath)) die(`no broadcast artefact at ${runPath}`);
  const run = JSON.parse(readFileSync(runPath, "utf8"));
  const created = run.transactions.filter((t) => t.transactionType === "CREATE").map((t) => t.contractAddress);
  if (created.length < 2) die(`artefact lists ${created.length} CREATEs — expected the factory and the curve`);

  console.log("\n  verifying every address has code on chain:");
  const factory = requireCode("VaultFactory", created[0], rpc);
  const bonding = requireCode("Bonding", created[1], rpc);

  // Derive the rest; never paste them.
  const feeVault = requireCode("FeeVault", cast(["call", bonding, "feeVault()(address)", "--rpc-url", rpc]), rpc);
  const lpLock = requireCode("LPLock", cast(["call", bonding, "lpLock()(address)", "--rpc-url", rpc]), rpc);

  const count = Number(cast(["call", factory, "vaultCount()(uint256)", "--rpc-url", rpc]).split(" ")[0]);
  const vaults = [];
  for (let i = 0; i < count; i++) {
    const v = cast(["call", factory, "vaults(uint256)(address)", String(i), "--rpc-url", rpc]);
    const sym = cast(["call", v, "symbol()(string)", "--rpc-url", rpc]).replace(/"/g, "");
    vaults.push({ address: requireCode(`vault ${sym}`, v, rpc), symbol: sym });
  }
  if (count === 0) die("factory lists zero vaults — the vault creations did not land");

  mkdirSync(DEPLOYMENTS, { recursive: true });
  const manifest = { schema: 1, chainId, custody, factory, bonding, feeVault, lpLock, vaults };
  writeFileSync(manifestPath(chainId), JSON.stringify(manifest, null, 2) + "\n");
  console.log(`\n  manifest -> ${manifestPath(chainId)}\n`);
}

// ------------------------------------------------------------------ lock

function lock() {
  if (env("CONFIRM") !== "LOCK") die("set CONFIRM=LOCK to lock");
  const rpc = env("KEEL_RPC_URL");
  const pk = env("KEEL_CUSTODY_KEY");
  const chainId = cast(["chain-id", "--rpc-url", rpc]);
  const m = loadManifest(chainId);

  const before = cast(["call", m.feeVault, "feeUnlockTime()(uint256)", "--rpc-url", rpc]).split(" ")[0];
  send(m.feeVault, "lockFees()", [], { rpc, pk });
  const after = cast(["call", m.feeVault, "feeUnlockTime()(uint256)", "--rpc-url", rpc]).split(" ")[0];

  const added = before === "0" ? "first lock" : `+${(BigInt(after) - BigInt(before)) / 86400n} day`;
  console.log(`\n  fee unlock ${before} -> ${after}  (${added})`);
  console.log(`  locked now: ${cast(["call", m.feeVault, "feesAreLocked()(bool)", "--rpc-url", rpc])}\n`);
}

// ------------------------------------------------------------------ exit

/** No dry run, no confirm word, no "are you sure". Calling it is doing it. */
function exit() {
  const rpc = env("KEEL_RPC_URL");
  const pk = env("KEEL_CUSTODY_KEY");
  const to = env("KEEL_EXIT_RECIPIENT");
  const chainId = cast(["chain-id", "--rpc-url", rpc]);
  const m = loadManifest(chainId);
  const USDT = "0x55d398326f99059fF775485246999027B3197955";

  const bal = (who) => cast(["call", USDT, "balanceOf(address)(uint256)", who, "--rpc-url", rpc]).split(" ")[0];
  const before = bal(to);
  const accrued = cast(["call", m.feeVault, "protocolAccrued()(uint256)", "--rpc-url", rpc]).split(" ")[0];
  console.log(`\n  protocolAccrued ${accrued}`);

  // The quote-side asset first: it is what the owner actually wants back.
  let swept = false;
  try {
    send(m.feeVault, "sweepProtocol(address)", [to], { rpc, pk, fatal: false });
    swept = true;
  } catch (e) {
    const why = /execution reverted: ([^",]+)/.exec(e.stderr || e.message || "");
    console.log(`  !!  sweepProtocol did not run (${why ? why[1] : "see above"}) — continuing`);
  }

  // Never return early because one leg was empty. Name every contract that can hold value.
  console.log("\n  residual balances, named one by one:");
  for (const [label, addr] of [
    ["FeeVault", m.feeVault],
    ["Bonding", m.bonding],
    ["LPLock", m.lpLock],
    ...m.vaults.map((v) => [`vault ${v.symbol}`, v.address]),
  ]) {
    console.log(`    ${label.padEnd(16)} ${addr}  USDT ${bal(addr)}`);
  }

  const after = bal(to);
  console.log(`\n  recipient USDT ${before} -> ${after}   (swept: ${swept})`);
  console.log("  LPLock holds graduated LP permanently and is not part of exit — by design.\n");
}

const sub = process.argv[2];
if (sub === "deploy") deploy();
else if (sub === "lock") lock();
else if (sub === "exit") exit();
else die(`unknown subcommand ${sub}`);
