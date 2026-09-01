#!/usr/bin/env node
/**
 * Dump the vault and factory schemas from the deployed contracts.
 *
 * The tuple signatures are derived from the compiled ABI rather than typed in. A hand-written
 * one drifts the moment a struct gains a member, and it drifts silently: cast decoded a
 * vaultDataSchema() missing its trailing `isArray` without complaining, and the vaultUISchema()
 * signature -- three bools short -- died with "buffer overrun" that landed in the file as a
 * Node stack trace where a schema was supposed to be.
 */
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const RPC = process.env.KEEL_RPC_URL ?? "https://bsc-dataseed.bnbchain.org";
const dep = JSON.parse(await readFile(join(ROOT, "deployments/56.json"), "utf8"));
const FACTORY = dep.contracts.LeverVaultFactory;
const IMPL = dep.contracts.LeverVaultImplementation;

const abiOf = async (name) =>
  JSON.parse(await readFile(join(ROOT, `out/${name}.sol/${name}.json`), "utf8")).abi;

// Render a solidity type the way cast expects it, expanding tuples recursively.
const typeOf = (c) =>
  c.type.startsWith("tuple")
    ? `(${c.components.map(typeOf).join(",")})${c.type.slice("tuple".length)}`
    : c.type;

const sigOf = (abi, fn) => {
  const e = abi.find((x) => x.type === "function" && x.name === fn);
  if (!e) throw new Error(`${fn} not in ABI`);
  const ins = e.inputs.map(typeOf).join(",");
  const outs = e.outputs.map(typeOf).join(",");
  return `${fn}(${ins})(${outs})`;
};

const call = (to, sig, ...args) =>
  execFileSync("cast", ["call", to, sig, ...args, "--rpc-url", RPC], { encoding: "utf8" }).trim();

const facAbi = await abiOf("LeverVaultFactory");
const vaultAbi = await abiOf("LeverVault");

console.log("# Schemas, read from the deployed contracts on BNB Chain (56)");
console.log(`# factory        ${FACTORY}`);
console.log(`# implementation ${IMPL}`);
console.log("# Tuple signatures are derived from the compiled ABI by tools/dump-schema.mjs.\n");

for (const [label, addr, abi, fn, args] of [
  ["factory.vaultDataSchema()", FACTORY, facAbi, "vaultDataSchema", []],
  ["factory.isQuoteTokenSupported(address(0))", FACTORY, facAbi, "isQuoteTokenSupported",
   ["0x0000000000000000000000000000000000000000"]],
  ["factory.beacon()", FACTORY, facAbi, "beacon", []],
  ["implementation.description()", IMPL, vaultAbi, "description", []],
  ["implementation.vaultUISchema()", IMPL, vaultAbi, "vaultUISchema", []],
]) {
  const sig = sigOf(abi, fn);
  console.log(`## ${label}`);
  console.log(`# signature: ${sig}\n`);
  console.log(call(addr, sig, ...args));
  console.log();
}

// Written only if every call above succeeded; a partial dump is not a schema.
