#!/usr/bin/env python3
"""Run KeelProbe as one eth_call against live BNB Chain state, via state override."""
import json, sys, urllib.request, subprocess

RPC   = "https://bsc-dataseed.bnbchain.org"
ADDR  = "0x0000000000000000000000000000000000009999"
USDT  = "0x55d398326f99059fF775485246999027B3197955"
SLOT  = "0x8726b10dd9bc57e65c6809d78694fd2ba55eb5a5c0f94227306d7df17e725f21"  # USDT._balances[0x..9999]

RT = open("/tmp/keel_rt.txt").read().strip()

def call(base_in, lev, is_long, is_btc, loops):
    data = subprocess.run(
        ["cast", "calldata", "run(uint256,uint256,bool,bool,uint8)",
         str(base_in), str(lev), str(is_long).lower(), str(is_btc).lower(), str(loops)],
        capture_output=True, text=True).stdout.strip()
    seed = "0x" + hex(base_in * 2)[2:].rjust(64, "0")
    body = {"jsonrpc":"2.0","id":1,"method":"eth_call","params":[
        {"to":ADDR,"data":data,"gas":"0x5f5e100","from":ADDR}, "latest",
        {ADDR:{"code":RT,"balance":"0x0"}, USDT:{"stateDiff":{SLOT:seed}}}]}
    r = urllib.request.urlopen(urllib.request.Request(
        RPC, json.dumps(body).encode(), {"content-type":"application/json"}), timeout=180)
    d = json.loads(r.read())
    if "error" in d:
        msg = d["error"].get("message","")
        dd  = d["error"].get("data","") or ""
        reason = ""
        if len(dd) > 138:
            try: reason = bytes.fromhex(dd[138:]).decode(errors="replace").rstrip("\x00")
            except Exception: pass
        return None, (reason or msg)[:120]
    res = d["result"][2:]
    w = [int(res[i:i+64],16) for i in range(0,len(res),64)]
    keys = ["shares","rateAfterMint","leverage","totalAssets","baseOut","roundTripBps","supplyUsd","borrowUsd"]
    return dict(zip(keys,w)), None

if __name__ == "__main__":
    E = 10**18
    print(f"{'case':<26}{'lev':>7}{'supply$':>11}{'debt$':>11}{'NAV$':>10}{'health':>8}   note")
    cases = [
        ("BTC 2x long",  2*E, True,  True,  3),
        ("BTC 3x long",  3*E, True,  True,  3),
        ("BTC 2x short", 2*E, False, True,  3),
        ("BNB 3x long",  3*E, True,  False, 3),
    ]
    for label, lev, lng, btc, loops in cases:
        r, err = call(1000*E, lev, lng, btc, loops)
        if err:
            print(f"{label:<26}   REVERT: {err}")
        else:
            h = (r['supplyUsd']*0.8/r['borrowUsd']) if r['borrowUsd'] else 0
            print(f"{label:<26}{r['leverage']/E:>7.2f}{r['supplyUsd']/E:>11,.2f}"
                  f"{r['borrowUsd']/E:>11,.2f}{r['totalAssets']/E:>10,.2f}{h:>8.3f}"
                  f"   liq at -{(1-1/h)*100:.1f}%" if h else "")
