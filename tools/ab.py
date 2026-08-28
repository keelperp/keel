#!/usr/bin/env python3
"""Same-block A/B: direct pair vs WBNB hop, for the identical vault config."""
import json, urllib.request, subprocess
RPC="https://bsc-dataseed.bnbchain.org"; ADDR="0x0000000000000000000000000000000000009999"
USDT="0x55d398326f99059fF775485246999027B3197955"
SLOT="0x8726b10dd9bc57e65c6809d78694fd2ba55eb5a5c0f94227306d7df17e725f21"
RT=open("/tmp/keel_rt.txt").read().strip(); E=10**18
K=["shares","rate","lev","assets","baseOut","rtBps","supplyUsd","borrowUsd"]
def ab(base_in,lev,lng,btc,loops):
    data=subprocess.run(["cast","calldata","ab(uint256,uint256,bool,bool,uint8)",
        str(base_in),str(lev),str(lng).lower(),str(btc).lower(),str(loops)],
        capture_output=True,text=True).stdout.strip()
    body={"jsonrpc":"2.0","id":1,"method":"eth_call","params":[
        {"to":ADDR,"data":data,"gas":"0x5f5e100","from":ADDR},"latest",
        {ADDR:{"code":RT,"balance":"0x0"},USDT:{"stateDiff":{SLOT:"0x"+hex(base_in*4)[2:].rjust(64,"0")}}}]}
    r=urllib.request.urlopen(urllib.request.Request(RPC,json.dumps(body).encode(),
        {"content-type":"application/json"}),timeout=240)
    d=json.loads(r.read())
    if "error" in d:
        dd=d["error"].get("data","") or ""
        try: return None,bytes.fromhex(dd[138:]).decode(errors="replace").rstrip("\x00")[:100]
        except Exception: return None,str(d["error"].get("message",""))[:100]
    res=d["result"][2:]; w=[int(res[i:i+64],16) for i in range(0,len(res),64)]
    return (dict(zip(K,w[:8])), dict(zip(K,w[8:16]))), None
print(f"{'size':>9}{'lev':>5}  {'direct NAV':>11}{'direct rt':>10}  {'hop NAV':>10}{'hop rt':>9}   winner")
for size in [1_000, 5_000, 20_000]:
    for lev,loops in [(3*E,5)]:
        out,err=ab(size*E,lev,True,True,loops)
        if err: print(f"{size:>9,}  REVERT {err}"); continue
        d,h=out
        win = "direct" if d["rtBps"]>h["rtBps"] else "hop"
        print(f"{size:>9,}{lev//E:>5}  {d['assets']/E:>11,.2f}{d['rtBps']/100:>9.2f}%  "
              f"{h['assets']/E:>10,.2f}{h['rtBps']/100:>8.2f}%   {win}  "
              f"(+{abs(d['rtBps']-h['rtBps'])/100:.2f}pp)")
