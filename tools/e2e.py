#!/usr/bin/env python3
"""launch -> sell -> graduate as one eth_call against live BNB Chain state."""
import json, urllib.request, subprocess

RPC  = "https://bsc-dataseed.bnbchain.org"
ADDR = "0x0000000000000000000000000000000000009999"
USDT = "0x55d398326f99059fF775485246999027B3197955"
SLOT = "0x8726b10dd9bc57e65c6809d78694fd2ba55eb5a5c0f94227306d7df17e725f21"
RT = open("/tmp/e2e_rt.txt").read().strip()
E = 10**18

KEYS = ["seedTokens","backingAfterSeed","vaultLeverage","soldBaseOut","backingAfterSell",
        "eligible","burnedAtGraduation","lpToLock","lpHeldByLock","unrestricted",
        "creatorFee","protocolFee"]

def run(seed, sell_bps):
    data = subprocess.run(["cast","calldata","run(uint256,uint256)",str(seed),str(sell_bps)],
                          capture_output=True, text=True).stdout.strip()
    body = {"jsonrpc":"2.0","id":1,"method":"eth_call","params":[
        {"to":ADDR,"data":data,"gas":"0x5f5e100","from":ADDR},"latest",
        {ADDR:{"code":RT,"balance":"0x0"},
         USDT:{"stateDiff":{SLOT:"0x"+hex(seed*3)[2:].rjust(64,"0")}}}]}
    r = urllib.request.urlopen(urllib.request.Request(
        RPC, json.dumps(body).encode(), {"content-type":"application/json"}), timeout=240)
    d = json.loads(r.read())
    if "error" in d:
        dd = d["error"].get("data","") or ""
        reason = ""
        if len(dd) > 138:
            try: reason = bytes.fromhex(dd[138:]).decode(errors="replace").rstrip("\x00")
            except Exception: pass
        return None, (reason or d["error"].get("message",""))[:160]
    res = d["result"][2:]
    w = [int(res[i:i+64],16) for i in range(0,len(res),64)]
    return dict(zip(KEYS,w)), None

if __name__ == "__main__":
    for seed, bps, label in [(20_000*E, 0,    "seed 20,000 USDT -> graduation"),
                             (25_000*E, 1500, "seed 25,000 USDT, sell 15%, then graduate"),
                             (13_000*E, 1000, "seed 13,000 USDT, sell 10% (below line)")]:
        r, err = run(seed, bps)
        print("="*62); print(label)
        if err: print("  REVERT:", err); continue
        print(f"  seed tokens          {r['seedTokens']/E:>18,.2f}")
        print(f"  backing after seed   {r['backingAfterSeed']/E:>18,.2f} USDT")
        print(f"  vault leverage       {r['vaultLeverage']/E:>18,.2f}x")
        print(f"  sold back            {r['soldBaseOut']/E:>18,.2f} USDT")
        print(f"  backing after sell   {r['backingAfterSell']/E:>18,.2f} USDT")
        print(f"  graduation eligible  {'YES' if r['eligible'] else 'no':>18}")
        print(f"  burned at graduation {r['burnedAtGraduation']/E:>18,.2f}")
        print(f"  LP held by LPLock    {r['lpHeldByLock']/E:>18,.6f}")
        print(f"  transfers unlocked   {'YES' if r['unrestricted'] else 'no':>18}")
        print(f"  creator fee          {r['creatorFee']/E:>18,.2f} USDT")
        print(f"  protocol fee         {r['protocolFee']/E:>18,.2f} USDT")
