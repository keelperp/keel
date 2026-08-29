#!/usr/bin/env python3
"""Prove the rebalance bounty actually executes and pays, on live BNB Chain state."""
import json, urllib.request, subprocess
RPC="https://bsc-dataseed.bnbchain.org"; ADDR="0x0000000000000000000000000000000000009999"
USDT="0x55d398326f99059fF775485246999027B3197955"
SLOT="0x8726b10dd9bc57e65c6809d78694fd2ba55eb5a5c0f94227306d7df17e725f21"
RT=open("/tmp/keel_rt.txt").read().strip(); E=10**18
data=subprocess.run(["cast","calldata","rebalanceBounty()"],capture_output=True,text=True).stdout.strip()
body={"jsonrpc":"2.0","id":1,"method":"eth_call","params":[
    {"to":ADDR,"data":data,"gas":"0x5f5e100","from":ADDR},"latest",
    {ADDR:{"code":RT,"balance":"0x0"},USDT:{"stateDiff":{SLOT:"0x"+hex(10**22)[2:].rjust(64,"0")}}}]}
r=urllib.request.urlopen(urllib.request.Request(RPC,json.dumps(body).encode(),
    {"content-type":"application/json"}),timeout=240)
d=json.loads(r.read())
assert "result" in d, d
res=d["result"][2:]
w=[int(res[i:i+64],16) for i in range(0,len(res),64)]
base=w[0]*2                      # struct is returned behind an offset word
f=[int(res[base+i*64:base+(i+1)*64],16) for i in range(8)]
soff=base+f[7]*2
ln=int(res[soff:soff+64],16)
reason=bytes.fromhex(res[soff+64:soff+64+ln*2]).decode()
print(f"  leverage after mint (maxLoops=1) {f[0]/E:>8.3f}x   target 3.000x")
print(f"  needsRebalance                   {'YES' if f[5] else 'no':>9}")
print(f"  bounty quoted                    {f[1]:>8} bps")
print(f"  supply before                    {f[2]/E:>12,.4f}")
print(f"  bounty minted to caller          {f[3]/E:>12,.4f} shares  ({f[3]*10000//f[2]} bps of supply)")
print(f"  leverage after rebalance         {f[4]/E:>8.3f}x")
print(f"  second call refused              {'YES' if f[6] else 'NO — GATE OPEN':>9}  ({reason!r})")
