#!/usr/bin/env node
/**
 * WHAT THIS GATE DOES NOT DO: it never compiles the component, and it knows nothing about
 * Flap's own rules. It passed for months while Component.tsx called `useFlapSdk(injected)` --
 * an API that does not exist -- and while every contract call was missing the `contract` label
 * that `vault:check` requires. The authority is Flap's checker, run from a checkout of the
 * template:
 *
 *   node scripts/vault-check.mjs keel
 *
 * The last run is committed at submission/vault-check.json. This file only guards the things
 * the checker does not: that VaultABI.ts is a faithful slice of the forge output, and that the
 * two locales stay in step.
 */
// Gate: every name the Vault UI component calls must exist in the generated ABI, and the
// generated ABI must match what forge just built. A drift here ships a button that reverts.
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const UI = join(ROOT, "vault-ui");
let fail = 0;
const say = (ok, msg) => {
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${msg}`);
  if (!ok) fail = 1;
};

for (const f of ["Component.tsx", "manifest.json", "VaultABI.ts", "i18n.json"]) {
  say(existsSync(join(UI, f)), `${f} present`);
}

// Regenerating must be a no-op; if it is not, the ABI is stale against the contracts.
const before = readFileSync(join(UI, "VaultABI.ts"), "utf8");
execFileSync("node", [join(ROOT, "tools", "gen-vault-abi.mjs")], { stdio: "pipe" });
say(readFileSync(join(UI, "VaultABI.ts"), "utf8") === before, "VaultABI.ts is current with forge output");

const src = readFileSync(join(UI, "Component.tsx"), "utf8");
const abi = readFileSync(join(UI, "VaultABI.ts"), "utf8");
const names = new Set([
  ...[...src.matchAll(/functionName:\s*"([A-Za-z_][A-Za-z0-9_]*)"/g)].map((m) => m[1]),
  ...[...src.matchAll(/read<[^>]+>\("([A-Za-z_][A-Za-z0-9_]*)"\)/g)].map((m) => m[1]),
  ...[...src.matchAll(/send\("([A-Za-z_][A-Za-z0-9_]*)"/g)].map((m) => m[1]),
]);
const missing = [...names].filter((n) => !abi.includes(`"name": "${n}"`));
say(missing.length === 0, `all ${names.size} names the component calls exist in the ABI${missing.length ? `: missing ${missing.join(", ")}` : ""}`);

// Both locales must carry the same keys, or one language renders blanks.
const i18n = JSON.parse(readFileSync(join(UI, "i18n.json"), "utf8"));
const en = Object.keys(i18n.en ?? {}).sort();
const zh = Object.keys(i18n.zh ?? {}).sort();
say(en.length > 0 && en.join() === zh.join(), `en and zh cover the same ${en.length} keys`);
const used = [...src.matchAll(/t\("([a-zA-Z]+)"\)/g)].map((m) => m[1]);
const unknown = [...new Set(used)].filter((k) => !en.includes(k));
say(unknown.length === 0, `every t() key is defined${unknown.length ? `: missing ${unknown.join(", ")}` : ""}`);

// The manifest still carries placeholders until the factory is deployed; say so out loud
// rather than letting a placeholder reach a package.
const man = JSON.parse(readFileSync(join(UI, "manifest.json"), "utf8"));
const raw = JSON.stringify(man);
if (raw.includes("REPLACE")) {
  console.log("  NOTE  manifest still has REPLACE placeholders — fill them after the factory is deployed");
}
process.exit(fail);
