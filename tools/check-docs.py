#!/usr/bin/env python3
"""Re-derive every published number from the build, and fail if a document disagrees.

The submission pages exist to be handed to an auditor, so a stale figure in one is worse than
no figure at all. This has already bitten: AUDIT.md carried a factory runtime of 5,173 when the
artefact was 6,476, an initcode of 26,963 against an actual 27,668, a pasted transcript claiming
9 offline tests when the suite declares 13, and a "60/40" split after the constant became 3000.
Nothing here is typed by hand -- the contract and the compiler are the only sources.
"""
import glob, json, os, pathlib, re, sys

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
            "site/index.html", "site/economics/index.html", "site/risks/index.html",
            "submission/README.md", "submission/FACTORY.md", "submission/MECHANISM.md",
            "submission/RULES.md", "submission/SPEC-CHECK.md", "submission/UI-REQUEST.md"]
W = re.compile(r"holders|持有者|project|项目方", re.I)
PCT = re.compile(r"(\d{1,3})%")
# A split written without a percent sign is still a split. Catch "60/40", and a bare number
# sitting next to holders/project, which is how three of these reached production.
BARE = re.compile(
    r"(?<![\d.])(\d{2})\s*/\s*(\d{2})(?![\d.%])"
    r"|(?<![\d.])(\d{2})\s+to\s+(?:holders|the project)"
    r"|(?:holders|the project)[^.\n]{0,12}?(?<![\d.])(\d{2})(?![\d.%])")
SUPERSEDED = {40, 60}          # the split before 2026-08-31; extend when it changes again
assert not (SUPERSEDED & {holder_pct, project_pct}), \
    "a superseded value equals the current split — update SUPERSEDED in this file"


# Proximity cannot decide whether a percentage is a share. It flagged a 2% tax and a 20%
# dividend as split errors, and then missed "Receives 40% of every harvest" because the word
# "project" sat one line above the 42-character window. So proximity is gone: a superseded
# value is a finding wherever it appears, and every legitimate use is named here.
ALLOWED_PHRASES = (
    # rule 008's gas headroom, which is a percentage of a gas cap and not a share
    "40% headroom", "余量 40%", "余量 **40%**", "| 24% | **40%** |",
    # the retired factory is cited on purpose, so nobody registers it by finding it first
    "described the project share as 40%",
    "share of each harvest as 40%",
    "Receives 40% of every harvest",
    "40% in the schema",
    # the liquidation chart's x-axis is a BNB drawdown scale, in the canvas and in the alt
    # text that describes the same picture
    'fillText("40%"',
    "minus 40%",
    "to minus 40%",
    "0% to minus 40",
)

for rel in SURFACES:
    body = read(rel)
    bad = []
    for m in PCT.finditer(body):
        if int(m.group(1)) not in SUPERSEDED:
            continue
        line = body[:m.start()].count(chr(10)) + 1
        window = body[max(0, m.start() - 60):m.end() + 40]
        if any(frag in window for frag in ALLOWED_PHRASES):
            continue
        bad.append(f"{rel}:{line} {m.group(0)}")
    for m in BARE.finditer(body):
        nums = [int(g) for g in m.groups() if g]
        hit = [n for n in nums if n in SUPERSEDED]
        if hit and not any(f in body[max(0, m.start()-60):m.end()+40] for f in ALLOWED_PHRASES):
            line = body[:m.start()].count(chr(10)) + 1
            bad.append(f"{rel}:{line} '{m.group(0).strip()}' (no % sign)")
    say(not bad, f"{rel} carries no superseded share" + (f" — {bad[:3]}" if bad else ""))

# The split is written in words too -- a test named ...SixtyAndProjectForty survived every
# numeric check because it contains no digits at all.
WORDS = {40: "forty", 60: "sixty", 30: "thirty", 70: "seventy"}
current = {WORDS[holder_pct], WORDS[project_pct]}
superseded_words = {WORDS[v] for v in SUPERSEDED if v in WORDS} - current
import glob as _glob
word_bad = []
for rel in sorted(set(SURFACES) | set(_glob.glob("test/*.sol")) | set(_glob.glob("src/flap/*.sol"))):
    raw = read(rel)
    for w in superseded_words:
        hit = (re.search(rf"\b{w}\b(?![-\w])", raw.lower())
               if rel.endswith((".md", ".html", ".json"))
               else w.capitalize() in raw or w in raw)
        if hit:
            word_bad.append(f"{rel} contains '{w}'")
say(not word_bad, "no file spells a superseded share in words" + (f" — {word_bad[:2]}" if word_bad else ""))

# A redeploy leaves stale pointers behind: the last one changed the factory address in five
# files and it was luck that no sixth existed. Every address a document names must be the one
# deployments/56.json records, and the on-chain schema must agree with the constant.
print("\n=== deployed addresses, as published vs as recorded ===")
dep = json.loads(read("deployments/56.json"))
live = dep["contracts"]["LeverVaultFactory"]
superseded_addr = dep.get("supersedes", {}).get("factory", "")
# Three addresses go stale together; checking only the factory let the retired beacon and
# implementation survive in four documents, including a verification recipe.
# Three addresses go stale together; checking only the factory let the retired beacon and
# implementation survive in four documents, including a verification recipe. The list lives in
# the manifest, not here, so a redeploy edits one file instead of a constant in the checker.
RETIRED = dep.get("retired", [])
say(len(RETIRED) >= 3, f"deployments/56.json carries the retired set ({len(RETIRED)} addresses)")
for name, a in dep["contracts"].items():
    if any(a.lower() == r.lower() for r in RETIRED):
        say(False, f"{name} {a[:12]}… is listed both as live and as retired")

MARKS = ("supersed", "retired", "replaces", "never be registered", "do not register",
         "previous", "作废", "已退役", "旧")

def marked_retired(body, addr):
    """True when this mention is explained as an old address rather than presented as current.
    Naming the retired set to say 'do not register this' is the right thing to do; only an
    unexplained mention is a defect."""
    low = body.lower()
    i = low.find(addr.lower())
    if i < 0:
        return True
    window = low[max(0, i - 400):i + 400]
    return any(w in window for w in MARKS)

for rel in ["AUDIT.md", "SUBMISSION.md", "README.md", "vault-ui/manifest.json",
            "submission/schema.txt", "submission/README.md", "submission/FACTORY.md",
            "submission/RULES.md", "submission/SPEC-CHECK.md", "submission/MECHANISM.md",
            "submission/UI-REQUEST.md"]:
    body = read(rel)
    unmarked = [a for a in ([superseded_addr] if superseded_addr else []) + RETIRED
                if a and a.lower() in body.lower() and not marked_retired(body, a)]
    if live.lower() not in body.lower() and "0x" + "0" * 40 not in body:
        say(False, f"{rel} never names the deployed factory {live}")
    elif unmarked:
        say(False, f"{rel} names retired address {unmarked[0][:12]}… without marking it as old")
    else:
        say(True, f"{rel} names the current deployment, and any old address is marked as old")
# The addresses were propagated on every redeploy but the block numbers were not: six files
# still named the third deployment's blocks, and one named a block older than that. A number
# stated beside an address has to come from the same manifest the address does.
d97 = json.loads(read("deployments/97.json"))
STAMPS = {f"{dep['block']:,}": "chain 56 block", f"{d97['block']:,}": "chain 97 block",
          dep["txHash"]: "chain 56 tx", d97["txHash"]: "chain 97 tx"}
stale = []
for rel in ["AUDIT.md", "SUBMISSION.md", "README.md", "submission/RULES.md", "submission/README.md",
            "submission/FACTORY.md", "submission/SPEC-CHECK.md", "submission/MECHANISM.md"]:
    body = read(rel)
    # Requiring a "block " prefix made this gate blind to the two stale numbers that actually
    # existed, which sat bare in a table. Match the shape, and exclude a trailing decimal so a
    # token amount of the same magnitude is not read as a block.
    for n in re.findall(r"(?<![\d.])(1[12][0-9],[0-9]{3},[0-9]{3})(?![\d.])", body):
        if n not in STAMPS:
            stale.append(f"{rel} says block {n}")
    for h in re.findall(r"0x[0-9a-fA-F]{64}", body):
        if h not in STAMPS and h not in body[:0]:
            stale.append(f"{rel} names tx {h[:12]}…")
say(not stale, "every block and tx in the documents is one the manifests record"
    + (f" — {stale[:2]}" if stale else ""))

# Making the factory upgradeable moved it behind a proxy, and a bulk replace then wrote three
# false claims: that the registered address is 7,145 bytes (it is a 279-byte proxy), that the
# retired factories are the same size as it, and that the constructor still builds the tree.
# Those survived because the size gate compares artefacts, and the registered address is no
# longer an artefact. Check the sentences instead.
print("\n=== nothing describes the superseded immutable-factory shape ===")
SUPERSEDED_SHAPE = [
    ("new LeverBeacon(address(new LeverVault()))", "the constructor no longer builds the tree"),
    ("new LeverBeacon(new LeverVault())", "the constructor no longer builds the tree"),
    ("three contracts", "five contracts are deployed now"),
    ("nonces 1 and 2", "the children are no longer the factory's own CREATEs"),
]
shape_bad = []
for rel in ["AUDIT.md", "SUBMISSION.md", "README.md", "submission/README.md", "submission/FACTORY.md",
            "submission/RULES.md", "submission/SPEC-CHECK.md", "submission/MECHANISM.md"]:
    body = read(rel)
    for phrase, why in SUPERSEDED_SHAPE:
        if phrase in body:
            shape_bad.append(f"{rel}: '{phrase}' — {why}")
say(not shape_bad, "no document still describes the immutable factory"
    + (f" — {shape_bad[:2]}" if shape_bad else ""))

# The registered address is a proxy; its size comes from the chain, not from out/. Pin the
# three numbers a reader can check with `cast codesize` so a redeploy cannot silently drift.
ONCHAIN_SIZES = {"0x1FBa768c7E78B83edAF99c5094a8ED44A5fdF45B": 279}
size_bad = []
for rel in ["submission/FACTORY.md", "submission/README.md", "submission/RULES.md",
            "AUDIT.md", "submission/SPEC-CHECK.md"]:
    body = read(rel)
    for addr, size in ONCHAIN_SIZES.items():
        for row in re.findall(rf"^\|[^\n]*{addr}[^\n]*$", body, re.M):
            # Search the SIZE CELL, not the whole row: the prose cell on this row also says
            # "279 bytes", so an any-position match passed even with the number falsified.
            cells = [c.strip().strip("`") for c in row.strip().strip("|").split("|")]
            hit = next((i for i, c in enumerate(cells) if addr.lower() in c.lower()), None)
            after = [c for c in cells[hit + 1:]] if hit is not None else []
            sizes = [int(c.replace(",", "")) for c in after if re.fullmatch(r"[\d,]{3,}", c)]
            if sizes and size not in sizes:
                size_bad.append(f"{rel} size cell for {addr[:10]}… says {sizes}, chain says {size}")
say(not size_bad, f"the registered proxy is described as {list(ONCHAIN_SIZES.values())[0]} bytes everywhere"
    + (f" — {size_bad[:2]}" if size_bad else ""))

# Both beacons must be named wherever the deployment is listed: naming only one was exactly the
# gap Flap's reviewer pointed at.
missing_fb = [rel for rel in ["submission/FACTORY.md", "submission/README.md", "submission/RULES.md"]
              if "0x8Ec0BA4aE3406427B05F21EeA80609B658b71fD5" not in read(rel)]
say(not missing_fb, "every deployment listing names the factory beacon too"
    + (f" — missing in {missing_fb}" if missing_fb else ""))

m = re.search(r"Receives (\d+)% of every harvest", read("submission/schema.txt"))
say(bool(m) and int(m.group(1)) == project_pct,
    f"on-chain schema says {m.group(1) if m else '?'}% == constant {project_pct}%")

print("\n=== every page's sizes, and nothing claiming it is unshipped ===")
PAGES = ["AUDIT.md", "SUBMISSION.md", "README.md", "submission/README.md",
         "submission/FACTORY.md", "submission/RULES.md", "submission/SPEC-CHECK.md",
         "submission/MECHANISM.md"]
# The size check above only read AUDIT.md, so a submission page could print the previous
# build's runtime beside the current address and still pass.
SUPERSEDED_SIZES = {19_462, 20_060, 5_173}
for rel in PAGES:
    body = read(rel)
    wrong = []
    for name, size in (("LeverVault", vault_rt), ("LeverVaultFactory", fac_rt)):
        for m in re.finditer(rf"{name}[^|\n]{{0,90}}?\|\s*([\d,]{{4,7}})\s*\|", body):
            got = int(m.group(1).replace(",", ""))
            line = body[body.rfind(chr(10), 0, m.start()) + 1:
                        body.find(chr(10), m.end()) if body.find(chr(10), m.end()) > 0 else len(body)]
            if got in SUPERSEDED_SIZES and got != size and f"{size:,}" not in line:
                wrong.append(f"{name} {m.group(1)} but the build is {size:,}")
    say(not wrong, f"{rel} prints no superseded size" + (f" — {wrong[0]}" if wrong else ""))

# A page saying the code is unshipped, after it shipped. Five documents said exactly this
# because they were written while the redeploy was happening.
UNSHIPPED = ("not on chain", "has not been deployed", "have not been deployed",
             "is not deployed", "predates this change", "not yet deployed",
             "尚未部署", "还没有部署")
SUBJECTS = ("implementation", "factory", "beacon", "contract", "vault", "floor",
            "max_swap_slip", "swap floor", "合约", "实现")
for rel in PAGES:
    low = read(rel).lower()
    hit = []
    for w in UNSHIPPED:
        i = low.find(w)
        while i >= 0:
            near = low[max(0, i - 200):i + 200]
            if any(sub in near for sub in SUBJECTS):
                hit.append(w); break
            i = low.find(w, i + 1)
    say(not hit, f"{rel} does not call the deployed contracts unshipped"
                 + (f" — '{hit[0]}'" if hit else ""))

print("\n=== test counts, as published vs as declared ===")
offline = len(re.findall(r"function test", read("test/LeverVaultSchema.t.sol")))
auth    = len(re.findall(r"function test", read("test/LeverVaultAuth.t.sol")))
# Every contract scripts/test.sh runs, rather than a list that goes stale when a suite is
# added -- which is exactly what happened when the underwater tests arrived.
suite = read("scripts/test.sh")
run_contracts = set(re.findall(r"--match-contract (\w+)", suite))
skipped = {"LeverVaultPositionTest"}   # archive-RPC only, gated behind KEEL_ARCHIVE
gas = 0
counted = []
for path in sorted(pathlib.Path(ROOT, "test").glob("*.t.sol")):
    src = path.read_text()
    m = re.search(r"contract (\w+) is Test", src)
    if not m or m.group(1) not in run_contracts or m.group(1) in skipped:
        continue
    n = len(re.findall(r"function test", src))
    counted.append((m.group(1), n))
    if m.group(1) not in ("LeverVaultSchemaTest", "LeverVaultAuthTest"):
        gas += n
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
