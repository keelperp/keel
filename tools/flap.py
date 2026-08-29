#!/usr/bin/env python3
"""Tax -> leveraged BNB position, one atomic eth_call on live BNB Chain state."""
import json, urllib.request, subprocess
RPC="https://bsc-dataseed.bnbchain.org"; ADDR="0x0000000000000000000000000000000000009999"
RT=open("/tmp/flap_rt.txt").read().strip(); E=10**18
K=["pendingAfterTax","deployBounty","navAfter","leverage","health",
   "supplyUsd","borrowUsd","costBasis","gasReceive","gasDeploy"]

def run(tax_wei, fund_wei):
    data=subprocess.run(["cast","calldata","run(uint256)",str(tax_wei)],
                        capture_output=True,text=True).stdout.strip()
    body={"jsonrpc":"2.0","id":1,"method":"eth_call","params":[
        {"to":ADDR,"data":data,"gas":"0x5f5e100","from":ADDR},"latest",
        {ADDR:{"code":RT,"balance":hex(fund_wei)}}]}
    r=urllib.request.urlopen(urllib.request.Request(RPC,json.dumps(body).encode(),
        {"content-type":"application/json"}),timeout=240)
    d=json.loads(r.read())
    if "error" in d:
        dd=d["error"].get("data","") or ""
        if dd.startswith("0x08c379a0"):
            b=dd[10:]; off=int(b[:64],16)*2; ln=int(b[off:off+64],16)
            return None, bytes.fromhex(b[off+64:off+64+ln*2]).decode(errors="replace")
        return None, str(d["error"].get("message",""))[:150]
    res=d["result"][2:]
    # Out is all-static, so the tuple is returned inline — no offset word.
    w=[int(res[i:i+64],16) for i in range(0,len(res),64)]
    assert len(w) >= len(K), f"got {len(w)} words, expected {len(K)}"
    return dict(zip(K,w[:len(K)])), None

if __name__=="__main__":
    for tax in [1, 5, 20]:
        r,err=run(tax*E, (tax+5)*E)
        print("="*58); print(f"tax batch: {tax} BNB")
        if err: print("  REVERT:", err); continue
        print(f"  pending after tax     {r['pendingAfterTax']/E:>12,.4f} BNB")
        print(f"  deploy bounty (0.25%) {r['deployBounty']/E:>12,.4f} BNB")
        print(f"  cost basis            {r['costBasis']/E:>12,.4f} BNB")
        print(f"  NAV after build       {r['navAfter']/E:>12,.4f} BNB")
        print(f"  leverage              {r['leverage']/E:>12,.3f}x")
        print(f"  health                {r['health']/10000:>12,.3f}   liq at -{(1-10000/r['health'])*100:.1f}%")
        print(f"  supply / debt (USD)   {r['supplyUsd']/E:>12,.2f} / {r['borrowUsd']/E:,.2f}")
        print(f"  gas: receive {r['gasReceive']:,}   deployPending {r['gasDeploy']:,}")

def harvest(tax_wei, gain_wei, fund_wei):
    HK=["navBeforeGain","navAfterGain","gainSeen","harvestBounty",
        "totalHarvested","navAfterHarvest","healthAfter","noGainGuard"]
    data=subprocess.run(["cast","calldata","harvestPath(uint256,uint256)",str(tax_wei),str(gain_wei)],
                        capture_output=True,text=True).stdout.strip()
    body={"jsonrpc":"2.0","id":1,"method":"eth_call","params":[
        {"to":ADDR,"data":data,"gas":"0x5f5e100","from":ADDR},"latest",
        {ADDR:{"code":RT,"balance":hex(fund_wei)}}]}
    r=urllib.request.urlopen(urllib.request.Request(RPC,json.dumps(body).encode(),
        {"content-type":"application/json"}),timeout=240)
    d=json.loads(r.read())
    if "error" in d:
        dd=d["error"].get("data","") or ""
        if dd.startswith("0x08c379a0"):
            b=dd[10:]; off=int(b[:64],16)*2; ln=int(b[off:off+64],16)
            return None, bytes.fromhex(b[off+64:off+64+ln*2]).decode(errors="replace")
        return None, ("EMPTY REVERT" if dd in ("","0x") else str(d["error"].get("message",""))[:120])
    res=d["result"][2:]
    w=[int(res[i:i+64],16) for i in range(0,len(res),64)]
    return dict(zip(HK,w[:len(HK)])), None
