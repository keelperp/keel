#!/usr/bin/env python3
"""
Keel live-state verification suite.

Every check below runs as ONE atomic `eth_call` against BNB Chain as it stands right now,
with the probe's bytecode injected by state override. Nothing is broadcast and no key is
used.

Why this and not a forge fork: these paths take ~50s of wall clock through Venus and
PancakeSwap. BSC public nodes prune state after roughly 96 seconds and there is no free
archive node, so a forked suite dies partway with `missing trie node` — verified against
both a direct fork and a local anvil cache. An atomic call cannot be pruned out from under
itself, runs against current state rather than a historical snapshot, and needs nothing
but a public RPC to reproduce.

Usage:  forge build && python3 tools/verify.py     # exits non-zero on any failure
"""
import json, os, subprocess, sys, urllib.request

RPC = "https://bsc-dataseed.bnbchain.org"
PROBE = "0x0000000000000000000000000000000000009999"
TRIGGER_SERVICE = "0xcf4EE25035CF883895110f367F5BA8172416a7F9"
# A live Flap token whose dividendToken is WBNB, which is what this vault requires.
TOKEN = "0x35764c47AB7F6B78B00636d4f8599F05f48d7777"
E = 10**18

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARTEFACT = os.path.join(ROOT, "out", "FlapProbe.sol", "FlapProbe.json")
if not os.path.exists(ARTEFACT):
    sys.exit(f"\n  ABORT: {ARTEFACT} not found — run `forge build` first.\n")
RT = json.load(open(ARTEFACT))["deployedBytecode"]["object"]
if len(RT) < 100:
    sys.exit("\n  ABORT: probe artefact has no bytecode.\n")

results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{'  — ' + detail if detail else ''}")
    return ok


def call(sig, args, at=PROBE, sender=None, balance=60 * E):
    data = subprocess.run(["cast", "calldata", sig, *[str(a) for a in args]],
                          capture_output=True, text=True).stdout.strip()
    body = {"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [
        {"to": at, "data": data, "gas": "0x5f5e100", "from": sender or at}, "latest",
        {at: {"code": RT, "balance": hex(balance)}}]}
    r = urllib.request.urlopen(urllib.request.Request(
        RPC, json.dumps(body).encode(), {"content-type": "application/json"}), timeout=240)
    d = json.loads(r.read())
    if "error" in d:
        dd = d["error"].get("data", "") or ""
        if dd.startswith("0x08c379a0"):
            b = dd[10:]
            off = int(b[:64], 16) * 2
            ln = int(b[off:off + 64], 16)
            raise RuntimeError(bytes.fromhex(b[off + 64:off + 64 + ln * 2]).decode(errors="replace"))
        raise RuntimeError("EMPTY REVERT" if dd in ("", "0x") else str(d["error"])[:120])
    return d["result"]


def words(hexstr):
    s = hexstr[2:]
    return [int(s[i:i + 64], 16) for i in range(0, len(s), 64)]


print("Keel — live-state verification (BNB Chain, atomic eth_call, nothing broadcast)\n")

# ---------------------------------------------------------------- build
print("build: tax becomes a leveraged position")
for tax in (1, 5, 20):
    w = words(call("run(uint256)", [tax * E]))
    k = dict(zip(["pending", "bounty", "nav", "lev", "health", "supply", "borrow", "basis",
                  "gasReceive", "gasDeploy"], w))
    lev, health = k["lev"] / E, k["health"] / 10000
    loss = 1 - k["nav"] / (tax * E - k["bounty"])
    check(f"{tax:>2} BNB — leverage in band", 2.90 <= lev <= 3.00, f"{lev:.3f}x")
    check(f"{tax:>2} BNB — health above the floor", health >= 1.20, f"{health:.3f}")
    check(f"{tax:>2} BNB — build costs under 1%", loss < 0.01, f"{loss * 100:.2f}%")
    check(f"{tax:>2} BNB — receive() under rule 005", k["gasReceive"] <= 1_000_000,
          f"{k['gasReceive']:,} / 1,000,000")

# ---------------------------------------------------------------- harvest
print("\nharvest: gain to holders and project, principal untouched")
for tax, gain in ((5, 1), (20, 4)):
    w = words(call("harvestPath(uint256,uint256,address)", [tax * E, gain * E, TOKEN], balance=90 * E))
    k = dict(zip(["navBefore", "navAfterGain", "gain", "bounty", "toHolders",
                  "navAfterHarvest", "health", "toProject", "noGainGuard"], w))
    freed = k["toHolders"] + k["toProject"] + k["bounty"]
    net = k["toHolders"] + k["toProject"]
    ratio = freed / k["gain"]
    check(f"gain {gain} BNB — frees the gain and no more", 0.98 <= ratio <= 1.02, f"{ratio:.3f}x")
    check(f"gain {gain} BNB — holders get 70%", abs(k["toHolders"] / net - 0.70) < 0.005,
          f"{k['toHolders'] / net * 100:.1f}%")
    check(f"gain {gain} BNB — project gets 30%", abs(k["toProject"] / net - 0.30) < 0.005,
          f"{k['toProject'] / net * 100:.1f}%")
    check(f"gain {gain} BNB — health holds after the unwind", k["health"] / 10000 >= 1.20,
          f"{k['health'] / 10000:.3f}")
    check(f"gain {gain} BNB — a second harvest is refused", k["noGainGuard"] == 1)

# ---------------------------------------------------------------- automatic settlement
print("\nautomatic settlement: the vault wakes itself")
w = words(call("autoPath(uint256,address)", [5 * E, TOKEN]))
k = dict(zip(["actionEmpty", "requestId", "secondsNext", "actionAfterTax",
              "doubleKick", "strangerTrigger", "wrongId", "fee"], w))
check("kickstart buys a real slot from FlapTriggerService", k["requestId"] > 0, f"id {k['requestId']}")
check("the slot is five minutes out", k["secondsNext"] == 300, f"{k['secondsNext']}s")
check("the fee is the service's quoted 0.0002 BNB", k["fee"] == 2 * 10**14, f"{k['fee'] / E:.6f} BNB")
check("a second kickstart is refused", k["doubleKick"] == 1)
check("a non-service caller cannot trigger", k["strangerTrigger"] == 1)

# The full callback, driven as the service itself.
raw = call("triggerLoop(uint256,address)", [5 * E, TOKEN], at=TRIGGER_SERVICE, sender=TRIGGER_SERVICE)
dec = subprocess.run(["cast", "abi-decode",
                      "f()((uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint8,string))",
                      raw], capture_output=True, text=True).stdout
vals = [x.strip() for x in dec.replace("(", "").replace(")", "").split(",")]
g = dict(zip(["action", "pendingBefore", "navBefore", "nextId", "navAfter", "lev",
              "health", "pendingAfter", "gasUsed", "replay", "err"], vals))
gi = lambda key: int(g[key].split()[0])
check("callback deploys everything it was holding", gi("pendingAfter") == 0,
      f"{gi('pendingBefore') / E:.4f} -> 0 BNB")
check("callback reaches target leverage", 2.90 <= gi("lev") / E <= 3.00, f"{gi('lev') / E:.3f}x")
check("callback holds the health floor", gi("health") / 10000 >= 1.20, f"{gi('health') / 10000:.3f}")
check("callback fits rule 008's 2,000,000 gas cap", gi("gasUsed") <= 2_000_000,
      f"{gi('gasUsed'):,} — {(1 - gi('gasUsed') / 2_000_000) * 100:.0f}% headroom")
check("the next slot is booked before the work runs", gi("nextId") > 0)
check("replaying a spent request id is refused", gi("replay") == 1)

# ---------------------------------------------------------------- summary
passed = sum(1 for _, ok, _ in results if ok)
print(f"\n{passed}/{len(results)} checks passed")
sys.exit(0 if passed == len(results) else 1)
