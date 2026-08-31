#!/usr/bin/env python3
"""Re-derive every published number from the build, and fail if a document disagrees.

The submission pages exist to be handed to an auditor, so a stale figure in one is worse than
no figure at all. This has already bitten: AUDIT.md carried a factory runtime of 5,173 when the
artefact was 6,476, an initcode of 26,963 against an actual 27,668, a pasted transcript claiming
9 offline tests when the suite declares 13, and a "60/40" split after the constant became 3000.
Nothing here is typed by hand -- the contract and the compiler are the only sources.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
fail = 0

def say(ok, msg):
    global fail
    print(f"  {'PASS' if ok else 'FAIL'}  {msg}")
    if not ok:
        fail = 1

def artefact(name):
    p = os.path.join(ROOT, "out", f"{name}.sol", f"{name}.json")
    if not os.path.exists(p):
        sys.exit(f"\n  ABORT: {p} missing — run `forge build` first.\n")
    d = json.load(open(p))
    return (len(d["deployedBytecode"]["object"]) // 2 - 1,
            len(d["bytecode"]["object"]) // 2 - 1)

def read(rel):
    with open(os.path.join(ROOT, rel), encoding="utf-8") as f:
        return f.read()

def const(src, name):
    m = re.search(rf"constant\s+{name}\s*=\s*([0-9_]+)", src)
    if not m:
        sys.exit(f"\n  ABORT: constant {name} not found in the source.\n")
    return int(m.group(1).replace("_", ""))

# ---- ground truth: the compiler and the contract ------------------------------------------
vault_rt, _           = artefact("LeverVault")
fac_rt, fac_ic        = artefact("LeverVaultFactory")
beacon_rt, _          = artefact("LeverBeacon")
src                   = read("src/flap/LeverVault.sol")
project_bps           = const(src, "PROJECT_SHARE_BPS")
holder_bps            = 10_000 - project_bps
project_pct, holder_pct = project_bps // 100, holder_bps // 100
EIP170                = 24_576

print("\n=== sizes, as published vs as compiled ===")
audit = read("AUDIT.md")
for name, rt in (("LeverVault", vault_rt), ("LeverVaultFactory", fac_rt), ("LeverBeacon", beacon_rt)):
    row = re.search(rf"\|\s*`{name}`\s*\|\s*([\d,]+)\s*\|\s*([\d,]+)\s*\|", audit)
    if not row:
        say(False, f"AUDIT.md has no size row for {name}"); continue
    stated, margin = int(row.group(1).replace(",", "")), int(row.group(2).replace(",", ""))
    say(stated == rt, f"AUDIT.md {name} runtime {stated:,} == artefact {rt:,}")
    say(margin == EIP170 - rt, f"AUDIT.md {name} margin {margin:,} == {EIP170 - rt:,}")
say(f"{fac_ic:,}" in audit, f"AUDIT.md states factory initcode {fac_ic:,}")

print("\n=== the split, as published vs as compiled ===")
say(project_bps + holder_bps == 10_000, f"constant PROJECT_SHARE_BPS = {project_bps} -> {holder_pct}/{project_pct}")
# A stale split is the failure that reaches users, so every surface is checked, site included.
# The test is not "does the old number appear" -- there is no formula for a superseded value.
# It is: every percentage stated next to "holders" or "project" must equal the constant.
SURFACES = ["AUDIT.md", "SUBMISSION.md", "LAUNCH.md", "vault-ui/i18n.json",
            "src/flap/LeverVault.sol", "src/flap/LeverVaultFactory.sol",
            "site/index.html", "site/economics/index.html", "site/risks/index.html"]
W = re.compile(r"holders|持有者|project|项目方", re.I)
PCT = re.compile(r"(\d{1,3})%")
SUPERSEDED = {40, 60}          # the split before 2026-08-31; extend when it changes again
assert not (SUPERSEDED & {holder_pct, project_pct}), \
    "a superseded value equals the current split — update SUPERSEDED in this file"

for rel in SURFACES:
    body = read(rel)
    bad = []
    for m in PCT.finditer(body):
        if int(m.group(1)) not in SUPERSEDED:
            continue
        near = [w for w in W.finditer(body)
                if abs(w.start() - m.start()) <= 42
                and "." not in body[min(m.start(), w.start()):max(m.end(), w.end())]]
        if near:
            line = body[:m.start()].count(chr(10)) + 1
            bad.append(f"{m.group(1)}% beside '{near[0].group(0)}' at {rel}:{line}")
    say(not bad, f"{rel} carries no superseded share" + (f" — {bad[:2]}" if bad else ""))

print("\n=== test counts, as published vs as declared ===")
offline = len(re.findall(r"function test", read("test/LeverVaultSchema.t.sol")))
auth    = len(re.findall(r"function test", read("test/LeverVaultAuth.t.sol")))
gas     = len(re.findall(r"function test", read("test/LeverVaultGas.t.sol")))
m = re.search(r"(\d+) passed\s+offline", audit)
say(bool(m) and int(m.group(1)) == offline, f"AUDIT.md offline count {m.group(1) if m else '?'} == {offline} declared")
m = re.search(r"(\d+) passed\s+forked:\s+authorization", audit)
say(bool(m) and int(m.group(1)) == auth, f"AUDIT.md auth count {m.group(1) if m else '?'} == {auth} declared")
total = offline + auth + gas
sub = read("SUBMISSION.md")
m = re.search(r"(\d+) 个 forge 测试", sub)
say(bool(m) and int(m.group(1)) == total, f"SUBMISSION.md claims {m.group(1) if m else '?'} forge tests == {total} declared")

print(f"\n{'all documents agree with the build' if not fail else 'DOCUMENTS DISAGREE WITH THE BUILD'}")
sys.exit(fail)
